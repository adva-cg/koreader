local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local PathChooser = require("ui/widget/pathchooser")
local logger = require("logger")
local Trapper = require("ui/trapper")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local l = require("gettext")
local T = require("ffi/util").template

local Anchoring = require("anchoring")
local SyncDB = require("sync_db")

local AUTO_SHARED_SETTING = "bookmarks_sync_auto_shared"
local BATCH_SIZE = 10
local BATCH_PAUSE_SEC = 0.25

local BookmarkSync = WidgetContainer:extend {
    name = "bookmarks_sync",
    title = l("Bookmarks Sync"),
    is_doc_only = true,
    device_id = nil,
    format = nil,
    book_id = nil,
    partial_md5 = nil,
    _is_importing = false,
    _book_ready = false,
    _shared_syncing = false,
    _exporting = false,
    _sync_hold = false,
}

function BookmarkSync:init()
    self.ui.menu:registerToMainMenu(self)
    self.device_id = G_reader_settings:readSetting("device_id")
    if not self.device_id then
        self.device_id = require("random").uuid()
        G_reader_settings:saveSetting("device_id", self.device_id)
    end
    -- Stable callback references for UIManager:unschedule
    self._runScheduledSharedSync = function()
        local opts = self._scheduled_shared_opts or { quiet = true }
        self._scheduled_shared_opts = nil
        Trapper:wrap(function()
            self:syncSharedFolder(opts)
        end)
    end
    self._runScheduledLocalThenShared = function()
        local opts = self._scheduled_local_opts or { quiet = true }
        self._scheduled_local_opts = nil
        Trapper:wrap(function()
            self:syncLocalThenShared(opts)
        end)
    end
end

function BookmarkSync:addToMainMenu(menu_items)
    menu_items.bookmarks_sync = {
        text = self.title,
        sub_item_table = {
            {
                text = l("Sync highlights and bookmarks now"),
                keep_menu_open = false,
                callback = function()
                    Trapper:wrap(function()
                        self:syncLocalThenShared({ quiet = true, after_import = true })
                        UIManager:show(InfoMessage:new {
                            text = l("Bookmarks sync completed successfully."),
                            timeout = 3,
                        })
                    end)
                end,
            },
            {
                text = l("Sync shared folder"),
                help_text = l("Merge the local bookmark store with the shared folder."),
                keep_menu_open = false,
                callback = function()
                    Trapper:wrap(function()
                        self:syncSharedFolder({ quiet = false, after_import = true })
                    end)
                end,
            },
            {
                text = l("Restore deleted bookmarks"),
                keep_menu_open = true,
                callback = function()
                    self:showRestoreDialog()
                end,
            },
            {
                text = l("Merge with another book"),
                help_text = l("Merge bookmarks from a differently named copy of this work into the current book. A backup is created first."),
                keep_menu_open = true,
                callback = function()
                    self:showMergeBooksDialog()
                end,
            },
            {
                text = l("Restore merge backup"),
                help_text = l("Undo a previous book merge using its backup."),
                keep_menu_open = true,
                callback = function()
                    self:showRestoreMergeBackupDialog()
                end,
            },
            {
                text = l("Reset applied status for this book"),
                help_text = l("Re-search anchors for bookmarks that were previously marked as applied on this device."),
                callback = function()
                    self:resetSyncStatus()
                end,
            },
            {
                text = l("Settings"),
                sub_item_table_func = function()
                    return self:getSettingsMenu()
                end,
            },
        }
    }
end

function BookmarkSync:getSettingsMenu()
    return {
        {
            text_func = function()
                local path = G_reader_settings:readSetting("bookmarks_sync_shared_path")
                if not path or path == "" then
                    return l("Shared folder: Not set")
                end
                if SyncDB.getSharedRoot() then
                    return T(l("Shared folder: %1"), path)
                end
                return T(l("Shared folder: %1 (unavailable)"), path)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:chooseSharedFolder(touchmenu_instance)
            end,
        },
        {
            text = l("Auto-sync shared folder"),
            help_text = l("When enabled, sync the shared folder whenever local bookmarks are saved, if the folder is available."),
            checked_func = function()
                return self:isAutoSharedEnabled()
            end,
            enabled_func = function()
                return G_reader_settings:readSetting("bookmarks_sync_shared_path") ~= nil
            end,
            callback = function(touchmenu_instance)
                local enabled = not self:isAutoSharedEnabled()
                G_reader_settings:saveSetting(AUTO_SHARED_SETTING, enabled)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
    }
end

function BookmarkSync:isAutoSharedEnabled()
    local value = G_reader_settings:readSetting(AUTO_SHARED_SETTING)
    if value == nil then
        return false
    end
    return value and true or false
end

function BookmarkSync:chooseSharedFolder(touchmenu_instance)
    local start = SyncDB.getSharedRoot()
        or G_reader_settings:readSetting("bookmarks_sync_shared_path")
        or G_reader_settings:readSetting("home_dir")
        or SyncDB.getLocalRoot()
    UIManager:show(PathChooser:new {
        select_file = false,
        path = start,
        onConfirm = function(path)
            SyncDB.setSharedRoot(path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            UIManager:show(InfoMessage:new {
                text = T(l("Shared folder set to:\n%1"), path),
                timeout = 3,
            })
        end,
    })
end

function BookmarkSync:ensureBookContext()
    local doc = self.ui.document
    if not doc or not doc.file then return false end
    -- Always run resolveBook so wiped by-fp / by-name links are recreated.
    SyncDB.migrateSidecar(doc.file, self.device_id)
    local book_id, fp, format = SyncDB.resolveBook(doc.file, self.device_id)
    if not book_id then return false end
    self.book_id = book_id
    self.partial_md5 = fp
    self.format = format
    self._book_ready = true
    return true
end

function BookmarkSync:resetSyncStatus()
    if not self:ensureBookContext() then
        UIManager:show(InfoMessage:new { text = l("No book is open.") })
        return
    end
    local root = SyncDB.getLocalRoot()
    local reset_count = 0
    -- Writing a new seen with journal 0 is wrong; instead markBack to force re-anchor,
    -- or simply remove the notion by creating back > seen. Plan: reset means clear applied
    -- by writing back so needsReanchor becomes true without deleting seen files.
    for _, mark in ipairs(SyncDB.listMarks(root, self.book_id)) do
        if SyncDB.isSeen(root, self.book_id, mark.datetime, self.device_id, self.partial_md5)
            and not SyncDB.isMarkGone(root, self.book_id, mark.datetime) then
            SyncDB.markBack(root, self.book_id, mark.datetime, self.device_id)
            reset_count = reset_count + 1
        end
    end
    if reset_count > 0 then
        local N_ = l.ngettext
        UIManager:show(InfoMessage:new {
            text = T(N_("Reset applied status for 1 bookmark.",
                "Reset applied status for %1 bookmarks.", reset_count), reset_count),
            timeout = 4,
        })
        UIManager:nextTick(function()
            self:importExternalBookmarks()
        end)
    else
        UIManager:show(InfoMessage:new {
            text = l("No bookmarks needed a status reset."),
            timeout = 3,
        })
    end
end

function BookmarkSync:showRestoreDialog()
    if not self:ensureBookContext() then
        UIManager:show(InfoMessage:new { text = l("No book is open.") })
        return
    end
    local root = SyncDB.getLocalRoot()
    local gone_marks = SyncDB.listGoneMarks(root, self.book_id)
    if #gone_marks == 0 then
        UIManager:show(InfoMessage:new {
            text = l("No deleted bookmarks to restore."),
            timeout = 3,
        })
        return
    end
    local buttons = {}
    for _, mark in ipairs(gone_marks) do
        local label = mark.exact or mark.datetime
        if #label > 60 then
            label = label:sub(1, 57) .. "…"
        end
        local datetime = mark.datetime
        table.insert(buttons, { {
            text = label,
            callback = function()
                SyncDB.markBack(root, self.book_id, datetime, self.device_id)
                UIManager:show(InfoMessage:new {
                    text = l("Bookmark restored."),
                    timeout = 2,
                })
                UIManager:nextTick(function()
                    self:importExternalBookmarks()
                end)
            end,
        } })
    end
    UIManager:show(ButtonDialog:new {
        title = l("Restore deleted bookmarks"),
        buttons = buttons,
    })
end

function BookmarkSync:showMergeBooksDialog()
    if not self:ensureBookContext() then
        UIManager:show(InfoMessage:new { text = l("No book is open.") })
        return
    end
    local root = SyncDB.getLocalRoot()
    local current_id = SyncDB.resolveRedirect(root, self.book_id)
    local books = SyncDB.listBookSummaries(root)
    local buttons = {}
    for _, book in ipairs(books) do
        if book.book_id ~= current_id then
            local label = book.label
            if #label > 70 then
                label = label:sub(1, 67) .. "…"
            end
            local from_id = book.book_id
            table.insert(buttons, { {
                text = label,
                callback = function()
                    UIManager:show(ConfirmBox:new {
                        text = T(l("Merge bookmarks from:\n%1\n\ninto the current book?\nA backup will be created first."), book.label),
                        ok_text = l("Merge"),
                        ok_callback = function()
                            local ok, bak_or_err = SyncDB.mergeBooks(root, current_id, { from_id }, self.device_id)
                            if not ok then
                                UIManager:show(InfoMessage:new {
                                    text = T(l("Merge failed: %1"), tostring(bak_or_err)),
                                    timeout = 4,
                                })
                                return
                            end
                            self.book_id = current_id
                            self._book_ready = true
                            UIManager:show(InfoMessage:new {
                                text = T(l("Books merged.\nBackup:\n%1"), bak_or_err),
                                timeout = 5,
                            })
                            UIManager:nextTick(function()
                                self:importExternalBookmarks()
                            end)
                        end,
                    })
                end,
            } })
        end
    end
    if #buttons == 0 then
        UIManager:show(InfoMessage:new {
            text = l("No other books found in the bookmark store."),
            timeout = 3,
        })
        return
    end
    UIManager:show(ButtonDialog:new {
        title = l("Merge into current book"),
        buttons = buttons,
    })
end

function BookmarkSync:showRestoreMergeBackupDialog()
    local root = SyncDB.getLocalRoot()
    local backups = SyncDB.listMergeBackups(root)
    if #backups == 0 then
        UIManager:show(InfoMessage:new {
            text = l("No merge backups found."),
            timeout = 3,
        })
        return
    end
    local buttons = {}
    for _, bak in ipairs(backups) do
        local from_labels = {}
        for _, id in ipairs(bak.from_ids) do
            local names = {}
            local by_name_dir = bak.path .. "/by-name"
            if lfs.attributes(by_name_dir, "mode") == "directory" then
                for name in lfs.dir(by_name_dir) do
                    if name ~= "." and name ~= ".."
                        and lfs.attributes(by_name_dir .. "/" .. name .. "/" .. id, "mode") then
                        table.insert(names, name)
                    end
                end
            end
            if #names == 0 then
                names = SyncDB.namesForBook(root, id)
            end
            table.insert(from_labels, #names > 0 and names[1] or id:sub(1, 8))
        end
        local label = T(l("%1 ← %2"), bak.time, table.concat(from_labels, ", "))
        if #label > 70 then
            label = label:sub(1, 67) .. "…"
        end
        local bak_path = bak.path
        table.insert(buttons, { {
            text = label,
            callback = function()
                UIManager:show(ConfirmBox:new {
                    text = T(l("Restore merge backup from %1?\nCurrent merge state for these books will be overwritten."), bak.time),
                    ok_text = l("Restore"),
                    ok_callback = function()
                        local ok, err = SyncDB.restoreMergeBackup(root, bak_path)
                        if not ok then
                            UIManager:show(InfoMessage:new {
                                text = T(l("Restore failed: %1"), tostring(err)),
                                timeout = 4,
                            })
                            return
                        end
                        self._book_ready = false
                        UIManager:show(InfoMessage:new {
                            text = l("Merge backup restored."),
                            timeout = 3,
                        })
                        if self.ui.document and self.ui.document.file then
                            UIManager:nextTick(function()
                                self:ensureBookContext()
                                self:importExternalBookmarks()
                            end)
                        end
                    end,
                })
            end,
        } })
    end
    UIManager:show(ButtonDialog:new {
        title = l("Restore merge backup"),
        buttons = buttons,
    })
end

function BookmarkSync:resolveConflictsSequentially(conflicts, index, on_done)
    index = index or 1
    if index > #conflicts then
        if on_done then on_done() end
        return
    end
    local conflict = conflicts[index]
    local a = conflict.local_data or {}
    local b = conflict.remote_data or {}
    local function preview(bm)
        local parts = {}
        if bm.exact then table.insert(parts, bm.exact) end
        if bm.notes or bm.note then table.insert(parts, T(l("Note: %1"), bm.notes or bm.note)) end
        if bm.color then table.insert(parts, T(l("Color: %1"), bm.color)) end
        if bm.drawer then table.insert(parts, T(l("Style: %1"), bm.drawer)) end
        local text = table.concat(parts, "\n")
        if #text > 400 then text = text:sub(1, 397) .. "…" end
        return text ~= "" and text or l("(empty)")
    end
    UIManager:show(MultiConfirmBox:new {
        text = T(l("Bookmark conflict.\n\nThis device:\n%1\n\nOther copy:\n%2"),
            preview(a), preview(b)),
        choice1_text = l("Keep this device"),
        choice2_text = l("Keep other copy"),
        choice1_callback = function()
            conflict.choice = "local"
            self:applyConflictChoice(conflict)
            self:resolveConflictsSequentially(conflicts, index + 1, on_done)
        end,
        choice2_callback = function()
            conflict.choice = "remote"
            self:applyConflictChoice(conflict)
            self:resolveConflictsSequentially(conflicts, index + 1, on_done)
        end,
        cancel_callback = function()
            -- Leave unresolved; previous version stays.
            self:resolveConflictsSequentially(conflicts, index + 1, on_done)
        end,
    })
end

function BookmarkSync:applyConflictChoice(conflict)
    if not conflict or not conflict.choice or not conflict.rel then return end
    local root = SyncDB.getLocalRoot()
    local chosen = conflict.choice == "local" and conflict.local_data or conflict.remote_data
    chosen = util.tableDeepCopy(chosen)
    chosen.loc = SyncDB.mergeLoc(
        (conflict.local_data and conflict.local_data.loc) or {},
        (conflict.remote_data and conflict.remote_data.loc) or {}
    )
    SyncDB.writeLua(root .. "/" .. conflict.rel, chosen)
    local _, log_rel = SyncDB.appendJournal(root, conflict.rel, self.device_id)
    -- Re-queue for push to shared
    local pending = G_reader_settings:readSetting("bookmarks_sync_pending") or {}
    local function queue(rel)
        for _, p in ipairs(pending) do
            if p == rel then return end
        end
        table.insert(pending, rel)
    end
    queue(conflict.rel)
    queue(log_rel)
    G_reader_settings:saveSetting("bookmarks_sync_pending", pending)

    if conflict.conflict_path and lfs.attributes(conflict.conflict_path, "mode") == "file" then
        os.remove(conflict.conflict_path)
    end
    local shared = SyncDB.getSharedRoot()
    if shared then
        SyncDB.writeLua(shared .. "/" .. conflict.rel, chosen)
        for _, cpath in ipairs(SyncDB.findConflictCopies(shared, conflict.rel)) do
            os.remove(cpath)
        end
        SyncDB.appendJournal(shared, conflict.rel, self.device_id)
    end
end

--- Sync with the shared folder in a subprocess so the UI stays responsive.
-- Settings that live in memory (cursor/pending) are returned from the child and applied here.
-- @param opts.quiet if true, skip toasts when folder is missing/unavailable; still ask on conflicts
-- @param opts.after_import if true, import bookmarks after a successful push
function BookmarkSync:syncSharedFolder(opts)
    opts = opts or {}
    local quiet = opts.quiet
    if self._shared_syncing then
        return
    end
    if not SyncDB.getSharedRoot() then
        if not quiet then
            local configured = G_reader_settings:readSetting("bookmarks_sync_shared_path")
            UIManager:show(InfoMessage:new {
                text = configured
                    and l("Shared folder is not available.")
                    or l("Set the shared folder in Bookmarks Sync settings first."),
                timeout = 4,
            })
        end
        return
    end

    self._shared_syncing = true
    local device_id = self.device_id
    self:ensureBookContext()
    local push_opts = {
        book_id = self.book_id,
        partial_md5 = self.partial_md5,
        norm_name = self.ui.document and self.ui.document.file
            and SyncDB.normalizeName(SyncDB.getBaseName(self.ui.document.file))
            or nil,
    }
    local trap = quiet and nil or l("Syncing shared folder… (tap to cancel)")
    local completed, result = Trapper:dismissableRunInSubprocess(function()
        local conflicts = {}
        local ok, err = SyncDB.pullShared(device_id, function(conflict)
            -- Only plain tables cross the subprocess boundary.
            table.insert(conflicts, {
                kind = conflict.kind,
                rel = conflict.rel,
                local_data = conflict.local_data,
                remote_data = conflict.remote_data,
                conflict_path = conflict.conflict_path,
            })
            return nil
        end)
        if not ok then
            return {
                ok = false,
                err = err,
                cursor = SyncDB.getCursor(),
                pending = G_reader_settings:readSetting("bookmarks_sync_pending") or {},
            }
        end
        local pushed, perr = true, nil
        if #conflicts == 0 then
            pushed, perr = SyncDB.pushShared(device_id, push_opts)
        end
        return {
            ok = true,
            conflicts = conflicts,
            pushed = pushed,
            perr = perr,
            cursor = SyncDB.getCursor(),
            pending = G_reader_settings:readSetting("bookmarks_sync_pending") or {},
        }
    end, trap)

    if not completed then
        self._shared_syncing = false
        if not quiet then
            UIManager:show(InfoMessage:new {
                text = l("Shared folder sync cancelled."),
                timeout = 2,
            })
        end
        return
    end

    result = result or {}
    if result.cursor ~= nil then
        SyncDB.setCursor(result.cursor)
    end
    if result.pending then
        G_reader_settings:saveSetting("bookmarks_sync_pending", result.pending)
    end

    if not result.ok then
        self._shared_syncing = false
        if not quiet then
            UIManager:show(InfoMessage:new {
                text = result.err == "no_shared"
                    and l("Shared folder is not available.")
                    or l("Could not read the shared folder."),
                timeout = 4,
            })
        end
        return
    end

    local pending_conflicts = result.conflicts or {}

    local function finish_push()
        if #pending_conflicts > 0 then
            -- Conflicts were resolved on the UI thread; push remaining pending quietly in background.
            local push_done, push_result = Trapper:dismissableRunInSubprocess(function()
                local pushed, perr = SyncDB.pushShared(device_id, push_opts)
                return {
                    pushed = pushed,
                    perr = perr,
                    cursor = SyncDB.getCursor(),
                    pending = G_reader_settings:readSetting("bookmarks_sync_pending") or {},
                }
            end, quiet and nil or l("Updating shared folder… (tap to cancel)"))
            self._shared_syncing = false
            if not push_done then
                return
            end
            if push_result then
                if push_result.cursor ~= nil then
                    SyncDB.setCursor(push_result.cursor)
                end
                if push_result.pending then
                    G_reader_settings:saveSetting("bookmarks_sync_pending", push_result.pending)
                end
                if not push_result.pushed and not quiet then
                    UIManager:show(InfoMessage:new {
                        text = l("Could not update the shared folder."),
                        timeout = 4,
                    })
                    return
                end
            end
        else
            self._shared_syncing = false
            if result.pushed == false then
                if not quiet then
                    UIManager:show(InfoMessage:new {
                        text = result.perr == "no_shared"
                            and l("Shared folder is not available.")
                            or l("Could not update the shared folder."),
                        timeout = 4,
                    })
                end
                return
            end
        end

        if not quiet then
            UIManager:show(InfoMessage:new {
                text = l("Shared folder sync finished."),
                timeout = 3,
            })
        end
        if opts.after_import and self.ui.document and self.ui.document.file then
            UIManager:nextTick(function()
                self:importExternalBookmarks()
            end)
        end
    end

    if #pending_conflicts > 0 then
        self:resolveConflictsSequentially(pending_conflicts, 1, finish_push)
    else
        finish_push()
    end
end

function BookmarkSync:scheduleSharedSync(opts)
    self._scheduled_shared_opts = opts or { quiet = true }
    UIManager:unschedule(self._runScheduledSharedSync)
    -- Debounce so typing/highlight bursts don't stall the UI.
    UIManager:scheduleIn(10, self._runScheduledSharedSync)
end

function BookmarkSync:scheduleLocalThenShared(opts)
    self._scheduled_local_opts = opts or { quiet = true }
    UIManager:unschedule(self._runScheduledLocalThenShared)
    UIManager:scheduleIn(10, self._runScheduledLocalThenShared)
end

function BookmarkSync:holdSync(sec)
    self._sync_hold = true
    UIManager:unschedule(self._releaseSyncHold)
    if not self._releaseSyncHold then
        self._releaseSyncHold = function()
            self._sync_hold = false
        end
    end
    UIManager:scheduleIn(sec or 5, self._releaseSyncHold)
end

function BookmarkSync:shouldSkipAutoSync()
    return self._is_importing or self._exporting or self._shared_syncing or self._sync_hold
end

function BookmarkSync:applyChildSyncState(result)
    if not result then return end
    if result.cursor ~= nil then
        SyncDB.setCursor(result.cursor)
    end
    if result.pending then
        G_reader_settings:saveSetting("bookmarks_sync_pending", result.pending)
    end
end

--- Yield briefly so the UI can breathe between batches (requires Trapper:wrap).
function BookmarkSync:yieldPause(sec)
    local co = coroutine.running()
    if not co then return end
    UIManager:scheduleIn(sec or BATCH_PAUSE_SEC, function()
        coroutine.resume(co)
    end)
    coroutine.yield()
end

local function childSyncState()
    return {
        ok = true,
        cursor = SyncDB.getCursor(),
        pending = G_reader_settings:readSetting("bookmarks_sync_pending") or {},
    }
end

--- Export a list of annotation items into the store (used inside a subprocess).
function BookmarkSync:exportAnnotationItems(items)
    local doc = self.ui.document
    local total_pages = doc:getPageCount()
    if not total_pages or total_pages <= 0 then return end
    local root = SyncDB.getLocalRoot()
    local is_reflowable = not (doc.is_pdf or doc.is_djvu)
    for _, item in ipairs(items) do
        pcall(function()
            local exact, prefix, suffix = Anchoring.getAnchorContext(doc, item, 5)
            local pageno = is_reflowable and doc:getPageFromXPointer(item.page) or item.pageno
            local progress = (pageno or 0) / total_pages
            local loc = {
                [self.partial_md5] = {
                    format = self.format,
                    pos0 = item.pos0,
                    pos1 = item.pos1,
                    page = item.page,
                    pageno = item.pageno,
                    pboxes = item.pboxes,
                },
            }
            SyncDB.upsertMarkFromAnnotation(root, self.book_id, {
                datetime = item.datetime,
                progress = progress,
                exact = exact,
                prefix = prefix,
                suffix = suffix,
                drawer = item.drawer,
                color = item.color,
                notes = item.note or item.notes,
                loc = loc,
            }, self.device_id)
            if not SyncDB.isSeen(root, self.book_id, item.datetime, self.device_id, self.partial_md5) then
                SyncDB.markSeen(root, self.book_id, item.datetime, self.device_id, self.partial_md5)
            end
        end)
    end
end

--- Mark store entries gone when they disappeared from the open book.
function BookmarkSync:exportMarkGonePass(current_datetimes)
    local root = SyncDB.getLocalRoot()
    for _, mark in ipairs(SyncDB.listMarks(root, self.book_id)) do
        if not current_datetimes[mark.datetime] then
            local gone = SyncDB.isMarkGone(root, self.book_id, mark.datetime)
            local seen = SyncDB.isSeen(root, self.book_id, mark.datetime, self.device_id, self.partial_md5)
            local has_loc = mark.loc and mark.loc[self.partial_md5]
            if gone == false and seen and has_loc then
                SyncDB.markGone(root, self.book_id, mark.datetime, self.device_id)
                logger.dbg("bookmarks_sync: Marking bookmark as gone:", mark.datetime)
            end
        end
    end
end

--- Full export (blocking). Prefer exportLocalBookmarksBackground from UI paths.
function BookmarkSync:exportLocalBookmarks()
    logger.dbg("bookmarks_sync: exportLocalBookmarks started.")
    if not self:ensureBookContext() then return end
    local doc = self.ui.document
    local total_pages = doc:getPageCount()
    if not total_pages or total_pages <= 0 then return end
    local annotations = self.ui.annotation.annotations or {}
    local work = {}
    local current_datetimes = {}
    for _, item in ipairs(annotations) do
        if item.datetime and not item.deleted and not item.is_service_note then
            current_datetimes[item.datetime] = true
            table.insert(work, item)
        end
    end
    self:exportAnnotationItems(work)
    self:exportMarkGonePass(current_datetimes)
    logger.dbg("bookmarks_sync: exportLocalBookmarks finished.")
end

--- Export in batches of BATCH_SIZE. Finished batches stay saved if the user cancels.
function BookmarkSync:exportLocalBookmarksBackground(opts)
    opts = opts or {}
    if self._exporting then
        return false
    end
    if not self:ensureBookContext() then
        return false
    end
    local doc = self.ui.document
    local total_pages = doc and doc:getPageCount()
    if not total_pages or total_pages <= 0 then
        return false
    end

    local annotations = self.ui.annotation.annotations or {}
    local work = {}
    local current_datetimes = {}
    for _, item in ipairs(annotations) do
        if item.datetime and not item.deleted and not item.is_service_note then
            current_datetimes[item.datetime] = true
            table.insert(work, item)
        end
    end

    self._exporting = true
    local quiet = opts.quiet
    local total = #work
    local info
    if not quiet then
        info = InfoMessage:new {
            text = T(l("Saving bookmarks… 0/%1 (tap to cancel)"), total),
        }
        UIManager:show(info)
        UIManager:forceRePaint()
    end
    local trap = info or nil

    local cancelled = false
    local done = 0
    local offset = 1
    while offset <= total do
        local chunk = {}
        for i = offset, math.min(offset + BATCH_SIZE - 1, total) do
            table.insert(chunk, work[i])
        end
        if info then
            UIManager:close(info)
            info = InfoMessage:new {
                text = T(l("Saving bookmarks… %1/%2 (tap to cancel)"), done, total),
            }
            UIManager:show(info)
            UIManager:forceRePaint()
            trap = info
        end
        local chunk_items = chunk
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            self:exportAnnotationItems(chunk_items)
            return childSyncState()
        end, trap)
        if completed then
            self:applyChildSyncState(result)
            done = done + #chunk
            offset = offset + BATCH_SIZE
            if offset <= total then
                self:yieldPause(BATCH_PAUSE_SEC)
            end
        else
            cancelled = true
            logger.info("bookmarks_sync: Export cancelled after", done, "of", total)
            break
        end
    end

    if not cancelled then
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            self:exportMarkGonePass(current_datetimes)
            return childSyncState()
        end, trap)
        if completed then
            self:applyChildSyncState(result)
        else
            cancelled = true
        end
    end

    if info then
        UIManager:close(info)
    end
    self._exporting = false
    self:holdSync(5)
    return not cancelled
end

function BookmarkSync:syncLocalThenShared(opts)
    opts = opts or {}
    self:exportLocalBookmarksBackground({ quiet = opts.quiet ~= false })
    local shared_ok = SyncDB.getSharedRoot()
        and (opts.force_shared or self:isAutoSharedEnabled())
    if shared_ok then
        local shared_opts = {
            quiet = opts.quiet ~= false,
            after_import = opts.after_import,
        }
        if shared_opts.quiet then
            self:scheduleSharedSync(shared_opts)
        else
            self:syncSharedFolder(shared_opts)
        end
    elseif opts.after_import then
        self:importExternalBookmarks()
    end
end

function BookmarkSync:onReaderReady()
    logger.dbg("bookmarks_sync: onReaderReady triggered")
    local doc = self.ui.document
    if not doc or not doc.file then
        logger.dbg("bookmarks_sync: onReaderReady: no document or file.")
        return
    end
    self._book_ready = false
    if not self:ensureBookContext() then return end
    self:scheduleLocalThenShared({ quiet = true, after_import = true })
end

function BookmarkSync:onSaveSettings()
    logger.dbg("bookmarks_sync: onSaveSettings triggered. Exporting local bookmarks.")
    if self:shouldSkipAutoSync() then
        logger.dbg("bookmarks_sync: onSaveSettings skipped (sync hold).")
        return
    end
    self:scheduleLocalThenShared({ quiet = true })
end

function BookmarkSync:onAnnotationsModified(event)
    if self:shouldSkipAutoSync() then
        logger.dbg("bookmarks_sync: onAnnotationsModified skipped during sync/hold.")
        return
    end
    self:scheduleLocalThenShared({ quiet = true })
end

--- Apply found import results to the open book (main process).
function BookmarkSync:applyImportFound(found_bookmarks, local_by_datetime)
    local doc = self.ui.document
    local root = SyncDB.getLocalRoot()
    local is_reflowable = not (doc.is_pdf or doc.is_djvu)
    local imported_count = 0
    self._is_importing = true
    for _, item_data in ipairs(found_bookmarks) do
        if not local_by_datetime[item_data.datetime] then
            if item_data.drawer then
                local item = {
                    pos0 = item_data.pos0,
                    pos1 = item_data.pos1,
                    text = item_data.exact,
                    datetime = item_data.datetime or os.date("%Y-%m-%d %H:%M:%S"),
                    drawer = item_data.drawer,
                    color = item_data.color,
                    notes = item_data.notes,
                    chapter = self.ui.toc:getTocTitleByPage(item_data.page),
                }
                if is_reflowable then
                    item.page = item_data.pos0
                else
                    item.page = item_data.page
                    item.pboxes = item_data.pboxes
                        or doc:getPageBoxesFromPositions(item_data.page, item_data.pos0, item_data.pos1)
                    pcall(function() self.ui.highlight:writePdfAnnotation("save", item) end)
                end
                local index = self.ui.annotation:addItem(item)
                self.ui:handleEvent(Event:new("AnnotationsModified",
                    { item, nb_highlights_added = 1, index_modified = index }))
            else
                local pn_or_xp = is_reflowable and doc:getPageXPointer(item_data.page) or item_data.page
                local chapter = self.ui.toc:getTocTitleByPage(pn_or_xp)
                local text = chapter and chapter ~= "" and T(l("in %1"), chapter) or ""
                local item = {
                    page = pn_or_xp,
                    text = text,
                    chapter = chapter,
                    datetime = item_data.datetime,
                }
                local index = self.ui.annotation:addItem(item)
                self.ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = index }))
            end
            imported_count = imported_count + 1
            local_by_datetime[item_data.datetime] = true
        end

        local existing = SyncDB.readMark(root, self.book_id, item_data.datetime) or {
            datetime = item_data.datetime,
            exact = item_data.exact,
            drawer = item_data.drawer,
            color = item_data.color,
            notes = item_data.notes,
        }
        existing.loc = existing.loc or {}
        if not item_data.from_loc then
            existing.loc[self.partial_md5] = {
                format = self.format,
                pos0 = item_data.pos0,
                pos1 = item_data.pos1,
                page = item_data.page,
            }
            SyncDB.writeMark(root, self.book_id, existing, self.device_id, true)
        end
        SyncDB.markSeen(root, self.book_id, item_data.datetime, self.device_id, self.partial_md5)
    end
    self._is_importing = false
    return imported_count
end

function BookmarkSync:resolveImportAnchors(list)
    local doc = self.ui.document
    local subprocess_results = { found = {}, unfound = {} }
    for _, ext_bm in ipairs(list) do
        local found_in_subprocess = false
        local loc = ext_bm.loc and ext_bm.loc[self.partial_md5]
        if loc and loc.pos0 and (loc.page or loc.pageno) then
            found_in_subprocess = true
            table.insert(subprocess_results.found, {
                pos0 = loc.pos0,
                pos1 = loc.pos1,
                page = loc.page or loc.pageno,
                pboxes = loc.pboxes,
                exact = ext_bm.exact,
                datetime = ext_bm.datetime,
                drawer = ext_bm.drawer,
                color = ext_bm.color,
                notes = ext_bm.notes or ext_bm.note,
                from_loc = true,
            })
        else
            pcall(function()
                local pos0, pos1, page = Anchoring.findAnchor(doc, ext_bm, self.ui.view.state)
                if pos0 and page then
                    found_in_subprocess = true
                    table.insert(subprocess_results.found, {
                        pos0 = pos0,
                        pos1 = pos1,
                        page = page,
                        exact = ext_bm.exact,
                        datetime = ext_bm.datetime,
                        drawer = ext_bm.drawer,
                        color = ext_bm.color,
                        notes = ext_bm.notes or ext_bm.note,
                    })
                end
            end)
        end
        if not found_in_subprocess then
            table.insert(subprocess_results.unfound, ext_bm)
        end
    end
    return subprocess_results
end

function BookmarkSync:importExternalBookmarks()
    if not self:ensureBookContext() then return end
    local doc = self.ui.document
    local root = SyncDB.getLocalRoot()
    local marks = SyncDB.listMarks(root, self.book_id)
    if #marks == 0 then
        logger.dbg("bookmarks_sync: No bookmarks in store to import.")
        return
    end

    local local_annotations = self.ui.annotation.annotations or {}
    local local_by_datetime = {}
    for _, local_bm in ipairs(local_annotations) do
        if local_bm.datetime then
            local_by_datetime[local_bm.datetime] = true
        end
    end

    local bookmarks_to_import = {}
    for _, mark in ipairs(marks) do
        local gone = SyncDB.isMarkGone(root, self.book_id, mark.datetime)
        if gone then
            -- skip deleted
        elseif gone == nil then
            table.insert(bookmarks_to_import, { mark = mark, ambiguous = true })
        elseif local_by_datetime[mark.datetime] then
            if SyncDB.needsReanchor(root, self.book_id, mark.datetime, self.device_id, self.partial_md5)
                and not (mark.loc and mark.loc[self.partial_md5]) then
                table.insert(bookmarks_to_import, { mark = mark })
            end
        elseif SyncDB.needsReanchor(root, self.book_id, mark.datetime, self.device_id, self.partial_md5)
            or not SyncDB.isSeen(root, self.book_id, mark.datetime, self.device_id, self.partial_md5) then
            table.insert(bookmarks_to_import, { mark = mark })
        end
    end

    local ambiguous = {}
    local normal = {}
    for _, item in ipairs(bookmarks_to_import) do
        if item.ambiguous then
            table.insert(ambiguous, item.mark)
        else
            table.insert(normal, item.mark)
        end
    end

    local function do_import(list)
        if #list == 0 then
            if #ambiguous == 0 then
                logger.dbg("bookmarks_sync: No new bookmarks to import.")
            end
            return
        end

        local total = #list
        local info = InfoMessage:new {
            text = T(l("Syncing bookmarks… 0/%1 (tap to cancel)"), total),
        }
        UIManager:show(info)
        UIManager:forceRePaint()

        local imported_count = 0
        local unfound_bookmarks = {}
        local cancelled = false
        local processed = 0
        local offset = 1
        while offset <= total do
            local chunk = {}
            for i = offset, math.min(offset + BATCH_SIZE - 1, total) do
                table.insert(chunk, list[i])
            end
            UIManager:close(info)
            info = InfoMessage:new {
                text = T(l("Syncing bookmarks… %1/%2 (tap to cancel)"), processed, total),
            }
            UIManager:show(info)
            UIManager:forceRePaint()

            local chunk_list = chunk
            local completed, results = Trapper:dismissableRunInSubprocess(function()
                return self:resolveImportAnchors(chunk_list)
            end, info)

            if completed and results then
                imported_count = imported_count + self:applyImportFound(results.found or {}, local_by_datetime)
                for _, u in ipairs(results.unfound or {}) do
                    table.insert(unfound_bookmarks, u)
                end
                processed = processed + #chunk
                offset = offset + BATCH_SIZE
                if offset <= total then
                    self:yieldPause(BATCH_PAUSE_SEC)
                end
            else
                cancelled = true
                logger.info("bookmarks_sync: Import cancelled after", processed, "of", total)
                break
            end
        end

        UIManager:close(info)
        self:holdSync(8)

        local is_reflowable = not (doc.is_pdf or doc.is_djvu)
        if #unfound_bookmarks > 0 then
            local unfound_texts = {}
            for _, unfound_bm in ipairs(unfound_bookmarks) do
                SyncDB.markSeen(root, self.book_id, unfound_bm.datetime, self.device_id, self.partial_md5)
                table.insert(unfound_texts, unfound_bm.exact or unfound_bm.datetime)
            end
            local N_ = l.ngettext
            UIManager:show(InfoMessage:new {
                text = T(N_("Could not sync 1 bookmark. A note has been added to the book.",
                    "Could not sync %1 bookmarks. A note has been added to the book.", #unfound_texts), #unfound_texts),
                timeout = 5,
            })
            local service_note_text = T(l("The following %1 bookmarks could not be synced in this document format:\n"),
                #unfound_texts)
            for _, text in ipairs(unfound_texts) do
                service_note_text = service_note_text .. "\n• " .. text
            end
            local service_item_page, service_pos0, service_pos1
            if is_reflowable then
                service_item_page = doc:getPageXPointer(1)
                service_pos0 = service_item_page
                service_pos1 = service_item_page
            else
                service_item_page = 1
                service_pos0 = { page = 1, x = 10, y = 10 }
                service_pos1 = { page = 1, x = 20, y = 20 }
            end
            local service_item = {
                pos0 = service_pos0,
                pos1 = service_pos1,
                text = service_note_text,
                datetime = os.date("%Y-%m-%d %H:%M:%S"),
                drawer = "lighten",
                color = "red",
                notes = service_note_text,
                chapter = self.ui.toc:getTocTitleByPage(service_item_page),
                page = service_item_page,
                is_service_note = true,
            }
            self._is_importing = true
            local index = self.ui.annotation:addItem(service_item)
            self.ui:handleEvent(Event:new("AnnotationsModified",
                { service_item, nb_highlights_added = 1, index_modified = index }))
            self._is_importing = false
        end

        if imported_count > 0 then
            local N_ = l.ngettext
            local msg
            if cancelled then
                msg = T(N_("Synced 1 bookmark (cancelled, partial)",
                    "Synced %1 bookmarks (cancelled, partial)", imported_count), imported_count)
            else
                msg = T(N_("Synced 1 bookmark from another format",
                    "Synced %1 bookmarks from other formats", imported_count), imported_count)
            end
            UIManager:show(InfoMessage:new {
                text = msg,
                timeout = 3,
            })
            self.ui:handleEvent(Event:new("ForceRepaint"))
        elseif cancelled then
            UIManager:show(InfoMessage:new {
                text = l("Bookmark sync cancelled."),
                timeout = 2,
            })
        end
    end

    if #ambiguous > 0 then
        local function ask_next(i)
            if i > #ambiguous then
                do_import(normal)
                return
            end
            local mark = ambiguous[i]
            UIManager:show(MultiConfirmBox:new {
                text = T(l("Bookmark was both deleted and restored.\n\n%1\n\nWhat should be kept?"),
                    mark.exact or mark.datetime),
                choice1_text = l("Keep deleted"),
                choice2_text = l("Restore"),
                choice1_callback = function()
                    SyncDB.markGone(root, self.book_id, mark.datetime, self.device_id)
                    ask_next(i + 1)
                end,
                choice2_callback = function()
                    SyncDB.markBack(root, self.book_id, mark.datetime, self.device_id)
                    table.insert(normal, mark)
                    ask_next(i + 1)
                end,
                cancel_callback = function()
                    ask_next(i + 1)
                end,
            })
        end
        ask_next(1)
    else
        do_import(normal)
    end
end

return BookmarkSync
