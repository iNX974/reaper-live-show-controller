-- ============================================================
--  Setlist_Manager_Regions_ImGui_Styled.lua  (SAFE MODE + REMOTE)
--  Setlist-Manager für REAPER-Regions mit hübscher GUI,
--  Light/Dark, Fullscreen, Hilfe, UI-Scale, A/B-Datei-Sync
--  Version: 2.3 (Fixes: Persistenz, Pfade, JSON, SHOW-Readonly,
--                 robustes Region-Ende, Sync-Toleranzen, UX)
-- ============================================================


-- ============================================================
-- KAPITEL 1 — REQUIREMENTS, CONFIG & GLOBAL STATE
-- ============================================================

if not reaper or not reaper.ImGui_CreateContext then
  reaper.MB("ReaImGui ist nicht installiert.\nExtensions → ReaPack → Browse → 'ReaImGui' installieren, dann REAPER neu starten.", "Setlist Manager", 0)
  return
end

local APP = "Setlist Manager (Regions) – Styled"
local VER = "2.5"  -- Version 2.5 (Fail-safes, pcall, atomic writes)

-- Persistenz-Namespace für Settings
local EXT_NS = "SetlistMgrStyled"

local _, _script_path = reaper.get_action_context()
local SCRIPT_DIR = (_script_path and _script_path:match("^(.*)[/\\]")) or reaper.GetResourcePath()
local PATH_CONFIG = reaper.GetResourcePath() .. "/setlist_config.json"

local DIR_SET_DEFAULT = SCRIPT_DIR .. "/Setlists"
local DIR_SET = DIR_SET_DEFAULT
local PATH_STATUS_DEFAULT = SCRIPT_DIR .. "/status.json"
local PATH_STATUS = PATH_STATUS_DEFAULT

local WRITE_IVL = 0.50
local TIME_EPS = 0.08
local UI_SCALE = 1.20
local USE_ONLY_DEFAULT_FONT = true
local SHOW_WARNING = true

local ctx = reaper.ImGui_CreateContext(APP)
local FONT_UI, FONT_BIG, FONT_HUGE
local theme = "Dark"
local mode  = "EDIT"
local fullscreen = false
local last_write = 0
local is_playing = false
local prev_mode = mode
local last_play_pos = 0

local regions = {}
local setlist = { name = "My Set", entries = {} }
local files = {}
local current = 1
local selected_set_file = 1

local show_help_quick = false
local show_help_keys  = false
local show_help_about = false
local show_help_diag  = false

local show_warning_pending = SHOW_WARNING
local show_info_footer = false
local REMOTE_KEY = "SetlistMgrRemote"

local settings_dirty = false
local settings_last_save = 0
local SETTINGS_SAVE_IVL = 0.5

-- ===== NEU: Edit-Buffer für Settings-Eingaben =====
-- (Damit Eingaben nicht „zurückspringen“ und sauber übernommen werden können)
local INPUT = {
  status_path = "",   -- Bearbeitungspuffer für PATH_STATUS
  dir_set     = "",   -- Bearbeitungspuffer für DIR_SET
  set_name    = "",   -- Bearbeitungspuffer für Setlist-Namen im Settings-Menü
}
local settings_needs_apply = false  -- zeigt an, dass es ungespeicherte Änderungen gibt

-- Kleiner Helfer: UI-Fokus von Tasten nicht „wegfressen“
local function want_text_input()
  local io = reaper.ImGui_GetIO and reaper.ImGui_GetIO(ctx) or {}
  return (io and (io.WantCaptureKeyboard or io.WantTextInput)) and true or false
end

-- OS/Path Utils
local function is_windows() return reaper.GetOS():match("Win") ~= nil end
local function path_sep() return is_windows() and "\\" or "/" end
local function normalize_path(p)
  if not p or p=="" then return "" end
  -- Unify slashes based on OS
  if is_windows() then
    p = p:gsub("/", "\\")
  else
    p = p:gsub("\\", "/")
  end
  
  if p == "/" or p == "\\" then return p end
  if p:match("^%a:[/\\]$") then return p end -- "C:\" bzw. "C:/"
  -- UNC \\server\share
  if p:match("^[/\\][/\\][^/\\]+[/\\][^/\\]+[/\\]?$") then
    return (p:gsub("[/\\]+$", ""))
  end
  -- Normal: trailing Slashes entfernen
  return (p:gsub("[/\\]+$", ""))
end
local function path_join(a,b)
  if not a or a=="" then return b or "" end
  if not b or b=="" then return a end
  local sep = path_sep()
  a = a:gsub("[/\\]+$", "")
  b = b:gsub("^[/\\]+", "")
  return a .. sep .. b
end

-- Duration-Utils
local function region_duration_sec(r)
  if not r then return 0 end
  local d = (r.fin or 0) - (r.start or 0)
  if d < 0 then d = 0 end
  return d
end

local function entry_duration_sec(e)
  if not e then return 0 end
  local r = (e.region_idx and (function() for _,rr in ipairs(regions) do if rr.idx==e.region_idx then return rr end end end)()) or nil
  r = r or ((e.name and (function()
      for _,rr in ipairs(regions) do if rr.name==e.name then return rr end end
    end)()) or nil)
  return region_duration_sec(r)
end

local function setlist_total_minutes()
  local sum = 0
  for _, e in ipairs(setlist.entries) do
    sum = sum + entry_duration_sec(e)
  end
  return (sum / 60.0), sum
end

-- ===== Robustes JSON (flat) =====
local function json_escape_string(s)
  s = (s or "")
      :gsub('\\','\\\\')
      :gsub('"','\\"')
      :gsub('\r','\\r')
      :gsub('\n','\\n')
      :gsub('\t','\\t')
      :gsub(',', '\\u002C') -- <— wichtig: Kommata neutralisieren
  return s
end

local function json_unescape_string(s)
  s = (s or "")
      :gsub('\\u002C', ',')
      :gsub('\\r','\r')
      :gsub('\\n','\n')
      :gsub('\\t','\t')
      :gsub('\\"','"')
      :gsub('\\\\','\\')
  return s
end

local function json_of(t)
  local parts={}
  for k,v in pairs(t) do
    if type(v)=="string" then
      parts[#parts+1] = '"'..k..'":"'..json_escape_string(v)..'"'
    elseif type(v)=="boolean" then
      parts[#parts+1] = '"'..k..'":'..(v and "true" or "false")
    elseif type(v)=="number" then
      parts[#parts+1] = '"'..k..'":'..tostring(v)
    else
      parts[#parts+1] = '"'..k..'":null'
    end
  end
  return "{"..table.concat(parts,",").."}"
end

-- Einfache, aber robuste Flat-JSON-Parsing-Funktion
local function json_parse_flat(s)
  local i, n = 1, #s
  local function skip_ws()
    while i<=n do
      local c=s:sub(i,i)
      if c==" " or c=="\t" or c=="\r" or c=="\n" then i=i+1 else break end
    end
  end
  local function parse_string()
    i=i+1
    local start=i
    local buf={}
    while i<=n do
      local c=s:sub(i,i)
      if c=='\\' then
        buf[#buf+1]=s:sub(start,i-1)
        local nextc = s:sub(i+1,i+1)
        if nextc=="" then break end
        buf[#buf+1] = "\\"..nextc
        i = i + 2
        start = i
      elseif c=='"' then
        buf[#buf+1]=s:sub(start,i-1)
        i=i+1
        return json_unescape_string(table.concat(buf))
      else
        i=i+1
      end
    end
    return json_unescape_string(table.concat(buf))
  end
  local function parse_value()
    skip_ws()
    local c = s:sub(i,i)
    if c=='"' then
      return parse_string()
    end
    local start=i
    while i<=n do
      c = s:sub(i,i)
      if c=="," or c=="}" then break end
      i=i+1
    end
    local tok = s:sub(start,i-1):match("^%s*(.-)%s*$")
    if tok=="true" then return true end
    if tok=="false" then return false end
    if tok=="null" or tok=="" then return nil end
    local num = tonumber(tok)
    if num ~= nil then return num end
    return tok
  end

  local t={}
  skip_ws()
  if s:sub(i,i) ~= "{" then return t end
  i=i+1
  while true do
    skip_ws()
    if s:sub(i,i)=="}" then i=i+1 break end
    if s:sub(i,i)~='"' then break end
    local key = parse_string()
    skip_ws()
    if s:sub(i,i) ~= ":" then break end
    i=i+1
    local val = parse_value()
    t[key]=val
    skip_ws()
    local c=s:sub(i,i)
    if c=="," then i=i+1; goto continue end
    if c=="}" then i=i+1; break end
    ::continue::
  end
  return t
end

-- ============================================================
-- KAPITEL 2 — HILFSFUNKTIONEN (I/O, UI, UTILS)
-- ============================================================

local function ensure_dir(p) reaper.RecursiveCreateDirectory(p, 0) end
local function readf(p) local f=io.open(p,"rb") if not f then return nil end local c=f:read("*a") f:close() return c end
local function writef(p,s)
  -- Für Status-Datei: Ordner anlegen, falls nötig
  local dir = p:match("^(.*)[/\\].-$")
  if dir and dir ~= "" then ensure_dir(dir) end
  local f=io.open(p,"wb") if not f then return false end f:write(s) f:close() return true
end
local function now() return reaper.time_precise() end
local function get_play_state() local st=reaper.GetPlayState(); return (st&1)==1,(st&2)==2 end
local function display_size()
  if reaper.ImGui_GetDisplaySize then local w,h=reaper.ImGui_GetDisplaySize(ctx) return w,h end
  if reaper.ImGui_GetIO then local io=reaper.ImGui_GetIO(ctx) return io.DisplaySize_x, io.DisplaySize_y end
  return 1280,720
end
local function SliderNumber(label, value, minv, maxv)
  if reaper.ImGui_SliderDouble then
    return reaper.ImGui_SliderDouble(ctx, label, value, minv, maxv, "%.2f")
  else
    return reaper.ImGui_SliderFloat(ctx, label, value, minv, maxv, "%.2f")
  end
end

-- Duration-Utils
local function region_duration_sec(r)
  if not r then return 0 end
  local d = (r.fin or 0) - (r.start or 0)
  if d < 0 then d = 0 end
  return d
end

local function entry_duration_sec(e)
  if not e then return 0 end
  local r = (e.region_idx and (function() for _,rr in ipairs(regions) do if rr.idx==e.region_idx then return rr end end end)()) or nil
  r = r or ((e.name and (function()
      for _,rr in ipairs(regions) do if rr.name==e.name then return rr end end
    end)()) or nil)
  return region_duration_sec(r)
end

local function setlist_total_minutes()
  local sum = 0
  for _, e in ipairs(setlist.entries) do
    sum = sum + entry_duration_sec(e)
  end
  return (sum / 60.0), sum
end


-- ===== Settings-Persistenz (JSON File) =====
local function mark_settings_dirty() settings_dirty = true end

local function save_settings(force)
  local t = {
    theme = theme,
    ui_scale = UI_SCALE,
    dir_set = DIR_SET,
    path_status = PATH_STATUS,
    show_warning = SHOW_WARNING,
    use_only_default_font = USE_ONLY_DEFAULT_FONT,
    fullscreen = fullscreen,
    ver = VER
  }
  local now_t = now()
  if not force and (now_t - settings_last_save) < SETTINGS_SAVE_IVL and not settings_dirty then
    return
  end
  writef(PATH_CONFIG, json_of(t))
  settings_last_save = now_t
  settings_dirty = false
end

local function load_settings()
  local raw = readf(PATH_CONFIG)
  if raw and raw ~= "" then
    local t = json_parse_flat(raw)
    if t and next(t) ~= nil then
      theme = (t.theme=="Light") and "Light" or "Dark"
      UI_SCALE = tonumber(t.ui_scale or UI_SCALE) or UI_SCALE
      DIR_SET = normalize_path(t.dir_set or DIR_SET_DEFAULT)
      PATH_STATUS = t.path_status or PATH_STATUS
      SHOW_WARNING = (t.show_warning ~= false)
      USE_ONLY_DEFAULT_FONT = (t.use_only_default_font ~= false)
      fullscreen = (t.fullscreen == true)
    end
  else
    DIR_SET = DIR_SET_DEFAULT
  end
  settings_dirty = true
  save_settings(true)

  INPUT.status_path = PATH_STATUS or ""
  INPUT.dir_set     = DIR_SET or ""
  INPUT.set_name    = setlist.name or "My Set"
  settings_needs_apply = false
end

local function save_prefs() mark_settings_dirty() end
local function has_js_api() return reaper.JS_Dialog_BrowseForSaveFile ~= nil end

local function browse_for_status_path()
  local initial = (INPUT.status_path ~= "" and INPUT.status_path) or PATH_STATUS or (SCRIPT_DIR .. "/status.json")
  local dir = initial:match("^(.*)[/\\].-$") or SCRIPT_DIR
  local fn  = initial:match("^.*[/\\](.-)$") or "status.json"
  if has_js_api() then
    local ok, out = reaper.JS_Dialog_BrowseForSaveFile("Choose status.json", dir, fn, "JSON (*.json)\0*.json\0All files (*.*)\0*.*\0")
    if ok and out and out ~= "" then
      if not out:lower():match("%.json$") then out = path_join(out, "status.json") end
      return normalize_path(out)
    end
  elseif reaper.GetUserFileNameForSave then
    local ok, out = reaper.GetUserFileNameForSave(dir..path_sep()..fn, "Choose status.json", ".json")
    if ok and out and out ~= "" then return normalize_path(out) end
  else
    local ok, out = reaper.GetUserInputs("Status path", 1, "Path to status.json:", initial)
    if ok and out and out ~= "" then
      if not out:lower():match("%.json$") then out = path_join(out, "status.json") end
      return normalize_path(out)
    end
  end
  return nil
end

local function browse_for_dir()
  local initial = (INPUT.dir_set ~= "" and INPUT.dir_set) or DIR_SET or (SCRIPT_DIR.."/Setlists")
  local dir = initial
  if has_js_api() then
    local ok, out = reaper.JS_Dialog_BrowseForSaveFile("Choose Setlists folder", dir, "", "Folder\0*\0")
    if ok and out and out ~= "" then
      local only_dir = out:match("^(.*)[/\\].-$") or out
      return normalize_path(only_dir)
    end
  else
    local ok, out = reaper.GetUserInputs("Setlists folder", 1, "Path:", initial)
    if ok and out and out ~= "" then return normalize_path(out) end
  end
  return nil
end

-- ============================================================
-- KAPITEL 3 — REGIONS & SETLIST I/O
-- ============================================================

local function scan_regions()
  regions = {}
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = (num_markers or 0) + (num_regions or 0)
  for i=0, total-1 do
    local ok, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers3(0, i)
    if ok and isrgn then
      regions[#regions+1] = { idx=idx, name=(name~="" and name or ("Region "..idx)), start=pos, fin=rgnend }
    end
  end
  table.sort(regions, function(a,b) return a.start < b.start end)
end

local function R(id)
  for _,r in ipairs(regions) do
    if r.idx==id then return r end
  end
end

-- Case/Whitespace-toleranter Lookup
local function normalize_name(nm)
  nm = nm or ""
  nm = nm:gsub("^%s+",""):gsub("%s+$","")
  nm = nm:gsub("%s+"," ")
  return nm:lower()
end
local function R_by_name(name)
  if not name or name == "" then return nil end
  local key = normalize_name(name)
  for _, r in ipairs(regions) do
    if normalize_name(r.name) == key then return r end
  end
  return nil
end

local function refresh_files()
  files = {}
  ensure_dir(DIR_SET)
  local i=0
  while true do
    local fn = reaper.EnumerateFiles(DIR_SET, i); if not fn then break end
    if fn:match("%.reaplaylist%.txt$") then files[#files+1]=fn end
    i=i+1
  end
  table.sort(files)
  if selected_set_file > #files then selected_set_file = #files end
  if selected_set_file < 1 then selected_set_file = (#files>0) and 1 or 0 end
end

local function save_set()
  if #setlist.entries==0 then reaper.MB("Setlist ist leer.","Save",0) return end
  local ok, nm = reaper.GetUserInputs("Save Setlist",1,"Name:", setlist.name or "Set")
  if not ok or nm=="" then return end
  setlist.name = nm
  local path = path_join(DIR_SET, (nm:gsub("[^%w%-%._ ]","_")..".reaplaylist.txt"))
  local t = {"# "..nm}
  for _,e in ipairs(setlist.entries) do
    local rr = R(e.region_idx) or R_by_name(e.name)
    local nm_safe = (e.name or (rr and rr.name) or ""):gsub("[\r\n]", " "):gsub(";", ",")
    t[#t+1] = string.format("%d;%d;%s;%d", e.region_idx or -1, (e.continue~=false) and 1 or 0, nm_safe, e.loop and 1 or 0)
  end
  if writef(path, table.concat(t,"\n")) then refresh_files() end
end

local function load_set_by_index(i, remap_regions_by_name)
  if i<1 or i>#files then return false end
  local fn = files[i]
  local txt = readf(path_join(DIR_SET, fn)); if not txt then return false end
  local nm = fn:gsub("%.reaplaylist%.txt$","")
  local entries = {}
  for line in txt:gmatch("[^\r\n]+") do
    if not line:match("^#") and line:find(";") then
      local parts = {}
      for part in (line .. ";"):gmatch("([^;]*);") do
        parts[#parts+1] = part
      end
      local ridx = tonumber(parts[1] or "")
      local cont = (parts[2] == "1" or parts[2] == "true")
      local name = (parts[3] and parts[3] ~= "") and parts[3] or nil
      local loop = (parts[4] == "1" or parts[4] == "true")
      if remap_regions_by_name and name then
        local matching_region = R_by_name(name)
        ridx = matching_region and matching_region.idx or nil
      end
      if ridx or name then
        entries[#entries+1] = {region_idx=ridx, continue=cont, name=name, loop=loop}
      end
    end
  end
  setlist = {name=nm, entries=entries}
  current = 1
  return true
end

-- Rescan regions and load the setlist matching the active project's filename
-- whenever REAPER switches to another project.
local last_project = nil
local last_project_file = nil
local has_seen_project = false

local function load_active_project_setlist()
  local project, project_file = reaper.EnumProjects(-1, "")
  project_file = project_file or ""
  if has_seen_project and project == last_project and project_file == last_project_file then
    return
  end

  has_seen_project = true
  last_project = project
  last_project_file = project_file

  scan_regions()
  refresh_files()

  local project_name = project_file:match("^.*[/\\](.-)$") or project_file
  project_name = project_name:gsub("%.[Rr][Pp][Pp]$", "")
  local expected_file = project_name:gsub("[^%w%-%._ ]", "_"):lower() .. ".reaplaylist.txt"

  for i, fn in ipairs(files) do
    if fn:lower() == expected_file then
      selected_set_file = i
      if load_set_by_index(i, true) then return end
      break
    end
  end

  -- Do not leave the previous project's songs active if there is no match.
  setlist = {name = project_name ~= "" and project_name or "My Set", entries = {}}
  current = 1
  selected_set_file = 0
end

local function delete_set_by_index(i)
  if i<1 or i>#files then return end
  os.remove(path_join(DIR_SET, files[i])); refresh_files()
end


-- ============================================================
-- KAPITEL 4 — PLAYBACK, ENGINE & A/B-SYNC
-- ============================================================

local function play_entry(e)
  if not e then return end
  local r = (R(e.region_idx) or R_by_name(e.name)); if not r then return end
  local playing, paused = get_play_state()
  local pos = (reaper.GetPlayPosition and reaper.GetPlayPosition()) or reaper.GetCursorPosition()
  if paused or not playing then
    pos = reaper.GetCursorPosition()
  end

  if pos >= r.start and pos < (r.fin - TIME_EPS) then
    if paused then
      reaper.OnPauseButton() -- Resume play
    elseif not playing then
      reaper.OnPlayButton()
    end
  else
    reaper.SetEditCurPos(r.start, true, true)
    if paused then
      reaper.OnPauseButton()
    elseif not playing then
      reaper.OnPlayButton()
    end
  end
  is_playing = true
end

local function stop_play()
  reaper.OnStopButton()
  is_playing = false
end

local function cue_entry(e)
  if not e then return end
  local r = (R(e.region_idx) or R_by_name(e.name)); if not r then return end
  reaper.SetEditCurPos(r.start, true, false)
end

local function goto_i(i, autoplay)
  if #setlist.entries==0 then current=1 return end
  if i<1 then i=1 elseif i>#setlist.entries then i=#setlist.entries end
  current = i
  if autoplay then play_entry(setlist.entries[current]) else cue_entry(setlist.entries[current]) end
end

local function next_song(force_play) 
  if #setlist.entries>0 then 
    if current < #setlist.entries then
      goto_i(current+1, force_play or is_playing)
    else
      if is_playing then stop_play() end
    end
  end 
end
local function prev_song(force_play) 
  if #setlist.entries>0 then 
    if current > 1 then
      goto_i(current-1, force_play or is_playing)
    else
      goto_i(1, force_play or is_playing)
    end
  end 
end

-- >>> PATCH: status_build() schreibt HUD-Werte in die JSON
local function status_build()
  local e = setlist.entries[current]
  local playing, paused = get_play_state()
  local r = e and (R(e.region_idx) or R_by_name(e.name))

  local next_e = setlist.entries[current + 1]
  local next_name = ""
  if next_e then
    local next_r = R(next_e.region_idx) or R_by_name(next_e.name)
    next_name = (next_r and next_r.name) or next_e.name or ""
  end

  local continue_flag = (e and e.continue ~= false)
  local loop_flag = (e and e.loop == true)

  -- Total / elapsed / remaining
  local total, elapsed = 0, 0
  local pos = reaper.GetPlayPosition() or 0
  for i, entry in ipairs(setlist.entries) do
    local rr = R(entry.region_idx) or R_by_name(entry.name)
    if rr then
      local dur = math.max(0, (rr.fin or 0) - (rr.start or 0))
      total = total + dur
      if i < current then
        elapsed = elapsed + dur
      elseif i == current then
        local part = math.max(0, math.min(dur, pos - (rr.start or 0)))
        elapsed = elapsed + part
      end
    end
  end
  local remaining = math.max(0, total - elapsed)
  local eta_epoch = os.time() + math.floor(remaining + 0.5)

  return {
    set=setlist.name or "", index=current, total=#setlist.entries,
    playing=playing, paused=paused,
    region_name=r and r.name or "", region_idx=r and r.idx or -1,
    next_region_name=next_name, continue_flag=continue_flag, loop_flag=loop_flag,
    status=(playing and "play") or (paused and "pause") or "stop",
    ts=now(),
    playpos = pos,

    -- >>> HUD-Felder für separates Uhr/HUD-Script:
    total_sec = total,
    remaining_sec = remaining,
    eta_epoch = eta_epoch
  }
end

local function status_write()
  local t=now(); if t-last_write<WRITE_IVL then return end; last_write=t
  local tmp_path = PATH_STATUS .. ".tmp"
  local ok, data = pcall(status_build)
  if ok and writef(tmp_path, json_of(data)) then
    if is_windows() then os.remove(PATH_STATUS) end
    pcall(os.rename, tmp_path, PATH_STATUS)
  end
end

-- Stabilere End-Erkennung + Continue-Logik
local function engine()
  local e = setlist.entries[current]
  local playing = select(1, get_play_state())
  if e and playing then
    local r = R(e.region_idx) or R_by_name(e.name)
    if r then
      local pos = reaper.GetPlayPosition() or 0
      -- Lag-resistenter Check: Grenzübergang erkannt
      if last_play_pos < (r.fin - TIME_EPS) and pos >= (r.fin - TIME_EPS) and pos <= (r.fin + 2.0) then
        if e.loop then
          -- Nahtloser Loop: Playcursor an den Start der Region zurücksetzen
          reaper.SetEditCurPos(r.start, true, true)
          return
        elseif e.continue ~= false then
          -- Continue EIN: direkt den nächsten Eintrag starten (falls vorhanden)
          if current < #setlist.entries then
            next_song(true)
            return
          else
            stop_play()
            return
          end
        else
          -- Continue AUS: auf den nächsten Eintrag springen, aber NICHT starten
          if current < #setlist.entries then
            goto_i(current + 1, false) -- selektieren & Cursor setzen
          end
          stop_play()
          return
        end
      end
    end
  end

  -- >>> FIX: auch wenn REAPER bereits gestoppt hat, aber Cursor am Ende steht,
  --          trotzdem zur nächsten Region springen, falls Continue AUS.
  if not playing and #setlist.entries > 0 then
    local e2 = setlist.entries[current]
    if e2 and e2.continue == false then
      local r2 = R(e2.region_idx) or R_by_name(e2.name)
      if r2 then
        local pos = (reaper.GetCursorPosition and reaper.GetCursorPosition()) or (reaper.GetPlayPosition() or 0)
        if pos >= (r2.fin - TIME_EPS) and pos <= (r2.fin + 1.0) and current < #setlist.entries then
          goto_i(current + 1, false) -- selektieren & Cursor setzen, kein Autoplay
        end
      end
    end
  end
end


-- ============================================================
-- KAPITEL 5 — REMOTE/MIDI (ExtState)
-- ============================================================

local function handle_remote()
  local cmd = reaper.GetExtState(REMOTE_KEY, "cmd")
  if not cmd or cmd == "" then return end
  local playing, paused = get_play_state()
  if cmd == "play_toggle" then
    if playing then
      local e = setlist.entries[current]
      if e and e.loop then next_song(true) else reaper.OnPauseButton() end
    else
      play_entry(setlist.entries[current])
    end
  elseif cmd == "play" then
    local e = setlist.entries[current]
    if playing and e and e.loop then next_song(true) else play_entry(e) end
  elseif cmd == "next" then
    next_song()
  elseif cmd == "next_stop" then
    stop_play()
    next_song(false)
  elseif cmd == "prev" then
    prev_song()
  elseif cmd == "stop" then
    stop_play()
  elseif cmd == "fullscreen_toggle" then
    fullscreen = not fullscreen
    mark_settings_dirty()
    save_settings(true)
  else
    local n = cmd:match("^goto:(%d+)$")
    if n then goto_i(tonumber(n), playing) end
  end
  reaper.DeleteExtState(REMOTE_KEY, "cmd", true)
end


-- ============================================================
-- KAPITEL 6 — THEME & FONTS (SAFE MODE)
-- ============================================================

local function apply_theme()
  if theme == "Dark" then
    if reaper.ImGui_StyleColorsDark then
      local ok = pcall(reaper.ImGui_StyleColorsDark, ctx)
      if not ok then pcall(reaper.ImGui_StyleColorsDark) end
    end
  else
    if reaper.ImGui_StyleColorsLight then
      local ok = pcall(reaper.ImGui_StyleColorsLight, ctx)
      if not ok then pcall(reaper.ImGui_StyleColorsLight) end
    end
  end
  if reaper.ImGui_SetNextWindowBgAlpha then
    reaper.ImGui_SetNextWindowBgAlpha(ctx, 1.0)
  end
end
local function pop_theme() end

local function rebuild_fonts()
  if not USE_ONLY_DEFAULT_FONT then
    local sz_ui   = math.max(12, math.floor(18 * UI_SCALE))
    local sz_big  = math.max(16, math.floor(28 * UI_SCALE))
    local sz_huge = math.max(28, math.floor(54 * UI_SCALE))
    FONT_UI   = reaper.ImGui_CreateFont("sans-serif", sz_ui)
    FONT_BIG  = reaper.ImGui_CreateFont("sans-serif", sz_big)
    FONT_HUGE = reaper.ImGui_CreateFont("sans-serif", sz_huge)
    if FONT_UI   then reaper.ImGui_Attach(ctx, FONT_UI)   end
    if FONT_BIG  then reaper.ImGui_Attach(ctx, FONT_BIG)  end
    if FONT_HUGE then reaper.ImGui_Attach(ctx, FONT_HUGE) end
  end
  pcall(reaper.ImGui_BuildFontAtlas, ctx)
end


-- ============================================================
-- KAPITEL 7 — GUI: TOOLBAR, EDIT-PANEL, SHOW-PANEL
-- ============================================================

local function toolbar()
  if reaper.ImGui_BeginChild(ctx, "toolbar", 0, math.floor(42*UI_SCALE), 0) then
    if reaper.ImGui_Button(ctx, (mode=="EDIT" and "● " or "○ ").."Edit") then mode="EDIT" end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, (mode=="SHOW" and "● " or "○ ").."Show") then mode="SHOW" end
    reaper.ImGui_SameLine(ctx, 0, math.floor(16*UI_SCALE))

    if reaper.ImGui_Button(ctx, (theme=="Dark" and "🌙 Dark" or "🌞 Light")) then
      theme = (theme=="Dark") and "Light" or "Dark"
      mark_settings_dirty(); save_settings(true)
    end
    reaper.ImGui_SameLine(ctx, 0, math.floor(16*UI_SCALE))

    if mode=="SHOW" then
      if reaper.ImGui_Button(ctx, fullscreen and "⤢ Windowed (F)" or "⤢ Fullscreen (F)") then
        fullscreen = not fullscreen
        mark_settings_dirty(); save_settings(true)
      end
      reaper.ImGui_SameLine(ctx, 0, math.floor(16*UI_SCALE))
    end

    if reaper.ImGui_Button(ctx, "⏮ Prev") then prev_song() end
    local play_btn_label = "▶ Play"
    local playing, paused = get_play_state()
    if playing then
      local e = setlist.entries[current]
      if e and e.loop then
        play_btn_label = "⏭ Skip Loop"
      else
        play_btn_label = "⏸ Pause"
      end
    end

    if reaper.ImGui_Button(ctx, play_btn_label) then
      local e = setlist.entries[current]
      if playing then
        if e and e.loop then
          next_song(true)
        else
          reaper.OnPauseButton()
        end
      else
        play_entry(e)
      end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "⏹ Stop") then stop_play() end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "⏭ Next") then next_song() end

    reaper.ImGui_EndChild(ctx)
  end
end

-- SHOW-Mode: schreibgeschützt (Buttons/Checkboxen disabled)
local function begin_disabled_if_show()
  if mode=="SHOW" and reaper.ImGui_BeginDisabled then
    reaper.ImGui_BeginDisabled(ctx, true)
    return true
  end
  return false
end
local function end_disabled_if_show(active)
  if active and reaper.ImGui_EndDisabled then
    reaper.ImGui_EndDisabled(ctx)
  end
end

local function panel_edit()
  local avail_w = (reaper.ImGui_GetContentRegionAvail and select(1, reaper.ImGui_GetContentRegionAvail(ctx))) or 0
  local left_w  = math.floor(avail_w * 0.50)

  if reaper.ImGui_BeginChild(ctx, "regions", left_w, 0, 0) then
    reaper.ImGui_Text(ctx, "Regions")
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Reload") then scan_regions() end
    reaper.ImGui_Separator(ctx)

    if reaper.ImGui_BeginTable(ctx, "tbl_regions", 4,
        reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_Resizable()) then
      reaper.ImGui_TableSetupColumn(ctx, "Idx",  reaper.ImGui_TableColumnFlags_WidthFixed(), 40)
      reaper.ImGui_TableSetupColumn(ctx, "Name")
      reaper.ImGui_TableSetupColumn(ctx, "Len (min)", reaper.ImGui_TableColumnFlags_WidthFixed(), 90)
      reaper.ImGui_TableSetupColumn(ctx, "",     reaper.ImGui_TableColumnFlags_WidthFixed(), 80)
      reaper.ImGui_TableHeadersRow(ctx)

      for i, r in ipairs(regions) do
        local dur_min = region_duration_sec(r) / 60.0
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, tostring(r.idx))
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, r.name or "")
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, string.format("%.1f", dur_min))
        reaper.ImGui_TableNextColumn(ctx)
        if reaper.ImGui_Button(ctx, "Add##"..i) then
          setlist.entries[#setlist.entries+1] = { region_idx = r.idx, continue = true, name = r.name, loop = false }
          current = #setlist.entries
        end
      end
      reaper.ImGui_EndTable(ctx)
    end
    reaper.ImGui_EndChild(ctx)
  end

  reaper.ImGui_SameLine(ctx, 0, math.floor(10*UI_SCALE))

  if reaper.ImGui_BeginChild(ctx, "setlist", 0, 0, 0) then
    reaper.ImGui_Text(ctx, "Setlist")
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save") then save_set() end
    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_BeginCombo(ctx, "Load", files[selected_set_file] or "(keine)") then
      for i, fn in ipairs(files) do
        local sel = (i == selected_set_file)
        if reaper.ImGui_Selectable(ctx, fn, sel) then
          selected_set_file = i
          load_set_by_index(i)
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Delete") and files[selected_set_file] then
      local ret = reaper.MB("Delete "..files[selected_set_file].." ?", "Delete", 4)
      if ret == 6 then delete_set_by_index(selected_set_file) end
    end

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_Text(ctx, " Name:")
    local changed, nm = reaper.ImGui_InputText(ctx, "##setname", setlist.name or "", 256)
    if changed then setlist.name = nm end

    local total_min = setlist_total_minutes()
    reaper.ImGui_SameLine(ctx, 0, math.floor(16*UI_SCALE))
    reaper.ImGui_Text(ctx, string.format("Net playtime: %.1f min", total_min))

    reaper.ImGui_Separator(ctx)

    if reaper.ImGui_BeginTable(ctx, "tbl_setlist", 7,
        reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_Resizable()) then
      reaper.ImGui_TableSetupColumn(ctx, "#",     reaper.ImGui_TableColumnFlags_WidthFixed(), 28)
      reaper.ImGui_TableSetupColumn(ctx, "Song")
      reaper.ImGui_TableSetupColumn(ctx, "Continue", reaper.ImGui_TableColumnFlags_WidthFixed(), 90)
      reaper.ImGui_TableSetupColumn(ctx, "Loop",     reaper.ImGui_TableColumnFlags_WidthFixed(), 60)
      reaper.ImGui_TableSetupColumn(ctx, "Up",       reaper.ImGui_TableColumnFlags_WidthFixed(), 40)
      reaper.ImGui_TableSetupColumn(ctx, "Down",     reaper.ImGui_TableColumnFlags_WidthFixed(), 50)
      reaper.ImGui_TableSetupColumn(ctx, "Del",      reaper.ImGui_TableColumnFlags_WidthFixed(), 40)
      reaper.ImGui_TableHeadersRow(ctx)

      for i, e in ipairs(setlist.entries) do
        local r = R(e.region_idx) or R_by_name(e.name)
        if r and not e.name then e.name = r.name end

        reaper.ImGui_TableNextRow(ctx)

        reaper.ImGui_TableNextColumn(ctx)
        if reaper.ImGui_Selectable(ctx, string.format("%02d", i), i == current) then
          current = i
        end

        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, (r and r.name) or (e.name or "<missing>"))

        reaper.ImGui_TableNextColumn(ctx)
        local cont = (e.continue ~= false)
        local _, new = reaper.ImGui_Checkbox(ctx, "##cont"..i, cont)
        if new ~= cont then e.continue = new end

        reaper.ImGui_TableNextColumn(ctx)
        local lp = (e.loop == true)
        local _, new_lp = reaper.ImGui_Checkbox(ctx, "##loop"..i, lp)
        if new_lp ~= lp then e.loop = new_lp end

        reaper.ImGui_TableNextColumn(ctx)
        if reaper.ImGui_Button(ctx, "▲##"..i) and i > 1 then
          setlist.entries[i], setlist.entries[i-1] = setlist.entries[i-1], setlist.entries[i]
          if current == i then current = i-1 elseif current == i-1 then current = i end
        end

        reaper.ImGui_TableNextColumn(ctx)
        if reaper.ImGui_Button(ctx, "▼##"..i) and i < #setlist.entries then
          setlist.entries[i], setlist.entries[i+1] = setlist.entries[i+1], setlist.entries[i]
          if current == i then current = i+1 elseif current == i+1 then current = i end
        end

        reaper.ImGui_TableNextColumn(ctx)
        if reaper.ImGui_Button(ctx, "X##"..i) then
          table.remove(setlist.entries, i)
          if current > #setlist.entries then current = #setlist.entries end
          if current < 1 then current = 1 end
        end
      end

      reaper.ImGui_EndTable(ctx)
    end

    reaper.ImGui_EndChild(ctx)
  end
end

local function panel_show()
  reaper.ImGui_Text(ctx, "Setlist: "..(setlist.name or ""))
  reaper.ImGui_Separator(ctx)

  if reaper.ImGui_Button(ctx, "⏮ Prev") then prev_song() end
  reaper.ImGui_SameLine(ctx)
  local play_btn_label = "▶ Play"
  local playing, paused = get_play_state()
  if playing then
    local e = setlist.entries[current]
    if e and e.loop then
      play_btn_label = "⏭ Skip Loop"
    else
      play_btn_label = "⏸ Pause"
    end
  end

  if reaper.ImGui_Button(ctx, play_btn_label) then
    local e = setlist.entries[current]
    if playing then
      if e and e.loop then
        next_song(true)
      else
        reaper.OnPauseButton()
      end
    else
      play_entry(e)
    end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "⏹ Stop") then stop_play() end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "⏭ Next") then next_song() end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, fullscreen and "⤢ Windowed (F)" or "⤢ Fullscreen (F)") then
    fullscreen = not fullscreen
    mark_settings_dirty(); save_settings(true)
  end

  reaper.ImGui_Separator(ctx)

  if reaper.ImGui_BeginTable(ctx, "tbl_showlist", 7,
      reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_Resizable()) then
    reaper.ImGui_TableSetupColumn(ctx, "#",     reaper.ImGui_TableColumnFlags_WidthFixed(), 28)
    reaper.ImGui_TableSetupColumn(ctx, "Song")
    reaper.ImGui_TableSetupColumn(ctx, "Continue", reaper.ImGui_TableColumnFlags_WidthFixed(), 90)
    reaper.ImGui_TableSetupColumn(ctx, "Loop",     reaper.ImGui_TableColumnFlags_WidthFixed(), 60)
    reaper.ImGui_TableSetupColumn(ctx, "Up",       reaper.ImGui_TableColumnFlags_WidthFixed(), 40)
    reaper.ImGui_TableSetupColumn(ctx, "Down",     reaper.ImGui_TableColumnFlags_WidthFixed(), 50)
    reaper.ImGui_TableSetupColumn(ctx, "Del",      reaper.ImGui_TableColumnFlags_WidthFixed(), 40)
    reaper.ImGui_TableHeadersRow(ctx)

    for i, e in ipairs(setlist.entries) do
      local r = R(e.region_idx) or R_by_name(e.name)
      if r and not e.name then e.name = r.name end

      reaper.ImGui_TableNextRow(ctx)

      reaper.ImGui_TableNextColumn(ctx)
      if reaper.ImGui_Selectable(ctx, string.format("%02d", i), i == current) then
        current = i
      end

      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, (r and r.name) or (e.name or "<missing>"))

      -- SHOW-Mode schreibgeschützt
      local dis = begin_disabled_if_show()

      reaper.ImGui_TableNextColumn(ctx)
      local cont = (e.continue ~= false)
      local _, new = reaper.ImGui_Checkbox(ctx, "##cont_show"..i, cont)
      if new ~= cont then e.continue = new end

      reaper.ImGui_TableNextColumn(ctx)
      local lp = (e.loop == true)
      local _, new_lp = reaper.ImGui_Checkbox(ctx, "##loop_show"..i, lp)
      if new_lp ~= lp then e.loop = new_lp end

      reaper.ImGui_TableNextColumn(ctx)
      if reaper.ImGui_Button(ctx, "▲##show"..i) and i > 1 then
        setlist.entries[i], setlist.entries[i-1] = setlist.entries[i-1], setlist.entries[i]
        if current == i then current = i-1 elseif current == i-1 then current = i end
      end

      reaper.ImGui_TableNextColumn(ctx)
      if reaper.ImGui_Button(ctx, "▼##show"..i) and i < #setlist.entries then
        setlist.entries[i], setlist.entries[i+1] = setlist.entries[i+1], setlist.entries[i]
        if current == i then current = i+1 elseif current == i+1 then current = i end
      end

      reaper.ImGui_TableNextColumn(ctx)
      if reaper.ImGui_Button(ctx, "X##show"..i) then
        table.remove(setlist.entries, i)
        if current > #setlist.entries then current = #setlist.entries end
        if current < 1 then current = 1 end
      end

      end_disabled_if_show(dis)
    end

    reaper.ImGui_EndTable(ctx)
  end
end


-- ============================================================
-- KAPITEL 8 — HILFE- & INFO-POPUPS
-- ============================================================

local function draw_help_popups()
  if show_warning_pending then
    local w,h = display_size()
    reaper.ImGui_SetNextWindowPos(ctx, w*0.5, h*0.5, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
    reaper.ImGui_SetNextWindowSize(ctx, math.floor(560*UI_SCALE), 0, reaper.ImGui_Cond_Appearing())
    reaper.ImGui_OpenPopup(ctx, "Live Show Warning")
    show_warning_pending = false
  end
  if reaper.ImGui_BeginPopupModal(ctx, "Live Show Warning", true) then
    reaper.ImGui_TextWrapped(ctx,
      "Haftungsausschluss:\n\n" ..
      "Dieses Script wird ohne Gewähr bereitgestellt. " ..
      "Die Nutzung in Live-Situationen erfolgt ausdrücklich auf eigene Gefahr. " ..
      "Bitte vor dem Einsatz live ausführlich testen, um unerwartetes Verhalten zu vermeiden.")
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Button(ctx, "OK") then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end

  if show_help_quick then
    local w,h = display_size()
    reaper.ImGui_SetNextWindowPos(ctx, w*0.5, h*0.5, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
    reaper.ImGui_SetNextWindowSize(ctx, math.floor(560*UI_SCALE), 0, reaper.ImGui_Cond_Appearing())
    reaper.ImGui_OpenPopup(ctx, "Quick Start")
    show_help_quick = false
  end
  if reaper.ImGui_BeginPopupModal(ctx, "Quick Start", true) then
    reaper.ImGui_TextWrapped(ctx, "1. Setlist-Ordner wählen (Settings -> Setlist folder)\n2. Regions anlegen (Reload Regions)\n3. Regions in Setlist einfügen (Add)\n4. SHOW-Modus aktivieren für sichere Bedienung")
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Button(ctx, "OK##quick") then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end

  if show_help_keys then
    local w,h = display_size()
    reaper.ImGui_SetNextWindowPos(ctx, w*0.5, h*0.5, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
    reaper.ImGui_SetNextWindowSize(ctx, math.floor(560*UI_SCALE), 0, reaper.ImGui_Cond_Appearing())
    reaper.ImGui_OpenPopup(ctx, "Shortcuts")
    show_help_keys = false
  end
  if reaper.ImGui_BeginPopupModal(ctx, "Shortcuts", true) then
    reaper.ImGui_TextWrapped(ctx, "Leertaste: Play/Stop\nN: Nächster Song\nP: Vorheriger Song\nE: EDIT Modus\nH: SHOW Modus\nF: Fullscreen (nur im SHOW Modus)")
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Button(ctx, "OK##keys") then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end

  if show_help_about then
    local w,h = display_size()
    reaper.ImGui_SetNextWindowPos(ctx, w*0.5, h*0.5, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
    reaper.ImGui_SetNextWindowSize(ctx, math.floor(560*UI_SCALE), 0, reaper.ImGui_Cond_Appearing())
    reaper.ImGui_OpenPopup(ctx, "About & Support")
    show_help_about = false
  end
  if reaper.ImGui_BeginPopupModal(ctx, "About & Support", true) then
    reaper.ImGui_TextWrapped(ctx, "Setlist Manager (Regions) Styled\nVersion " .. VER .. "\n\nEin Script zur Steuerung von REAPER in Live-Situationen.")
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Button(ctx, "OK##about") then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end

  if show_help_diag then
    local w,h = display_size()
    reaper.ImGui_SetNextWindowPos(ctx, w*0.5, h*0.5, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
    reaper.ImGui_SetNextWindowSize(ctx, math.floor(560*UI_SCALE), 0, reaper.ImGui_Cond_Appearing())
    reaper.ImGui_OpenPopup(ctx, "Diagnostics")
    show_help_diag = false
  end
  if reaper.ImGui_BeginPopupModal(ctx, "Diagnostics", true) then
    reaper.ImGui_TextWrapped(ctx, "Current Mode: " .. mode .. "\nStatus File: " .. PATH_STATUS .. "\nRegions Count: " .. tostring(#regions) .. "\nSetlist Entries: " .. tostring(#setlist.entries))
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Button(ctx, "OK##diag") then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end
end


-- ============================================================
-- KAPITEL 9 — HOTKEYS (IM FRAME)
-- ============================================================

local function hotkeys_in_frame()
  local io = reaper.ImGui_GetIO and reaper.ImGui_GetIO(ctx) or {}
  local wantKeyboard = (io and (io.WantCaptureKeyboard or io.WantTextInput)) and true or false
  local anyItemActive = reaper.ImGui_IsAnyItemActive and reaper.ImGui_IsAnyItemActive(ctx) or false

  local windowFocused = true
  if reaper.ImGui_IsWindowFocused then
    local flags = reaper.ImGui_FocusedFlags_RootAndChildWindows and reaper.ImGui_FocusedFlags_RootAndChildWindows() or 0
    windowFocused = reaper.ImGui_IsWindowFocused(ctx, flags)
  end

  if wantKeyboard or anyItemActive or not windowFocused then
    return
  end

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space()) then
    local playing, paused = get_play_state()
    if playing then
      local e = setlist.entries[current]
      if e and e.loop then next_song(true) else reaper.OnPauseButton() end
    else
      play_entry(setlist.entries[current])
    end
  end
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_N()) then next_song() end
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_P()) then prev_song() end
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_E()) then mode="EDIT" end
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_H()) then mode="SHOW" end
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_F()) and mode=="SHOW" then fullscreen = not fullscreen; mark_settings_dirty(); save_settings(true) end
end


-- ============================================================
-- KAPITEL 10 — MAIN LOOP
-- ============================================================

local function run_main_logic()
  load_active_project_setlist()

  local playing,_ = get_play_state()
  is_playing = playing

  if mode ~= prev_mode then
    if mode == "SHOW" then fullscreen = true; mark_settings_dirty(); save_settings(true) end
    prev_mode = mode
  end

  handle_remote()

  local flags = reaper.ImGui_WindowFlags_MenuBar()
  if fullscreen and mode=="SHOW" then
    local w,h = display_size()
    reaper.ImGui_SetNextWindowPos(ctx, 0, 0, reaper.ImGui_Cond_Always())
    reaper.ImGui_SetNextWindowSize(ctx, w, h, reaper.ImGui_Cond_Always())
    flags = flags
      | reaper.ImGui_WindowFlags_NoDecoration()
      | reaper.ImGui_WindowFlags_NoMove()
      | reaper.ImGui_WindowFlags_NoResize()
  else
    reaper.ImGui_SetNextWindowSize(ctx, math.floor(1080*UI_SCALE), math.floor(720*UI_SCALE), reaper.ImGui_Cond_FirstUseEver())
  end

  apply_theme()
  local visible, open = reaper.ImGui_Begin(ctx, APP.."  "..VER.."  ["..mode.."]  ", true, flags)
  if visible then
    if reaper.ImGui_BeginMenuBar(ctx) then
      if reaper.ImGui_BeginMenu(ctx, "File") then
        if reaper.ImGui_MenuItem(ctx, "Save") then save_set() end
        if reaper.ImGui_MenuItem(ctx, "Reload regions") then scan_regions() end
        if reaper.ImGui_MenuItem(ctx, "Refresh setlists") then refresh_files() end
        if reaper.ImGui_MenuItem(ctx, "Exit") then open=false end
        reaper.ImGui_EndMenu(ctx)
      end
      if reaper.ImGui_BeginMenu(ctx, "Settings") then
        -- ===== Setlist-Name (Puffer, nicht sofort live) =====
        local changed_name, nm = reaper.ImGui_InputText(ctx, "Setlist name", INPUT.set_name or "", 256)
        if changed_name then INPUT.set_name = nm; settings_needs_apply = true end

        -- ===== Status-Pfad (Leader/Follower) =====
        if reaper.ImGui_InputText ~= nil then
          local changed_sp, sp = reaper.ImGui_InputText(ctx, "HUD output file", INPUT.status_path or "", 512)
          if changed_sp then INPUT.status_path = sp; settings_needs_apply = true end
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Browse…##status") then
          local p = browse_for_status_path()
          if p then INPUT.status_path = normalize_path(p); settings_needs_apply = true end
        end

        -- ===== Startup-Disclaimer =====
        local _, new_warn = reaper.ImGui_Checkbox(ctx, "Show startup disclaimer", SHOW_WARNING)
        if new_warn ~= SHOW_WARNING then
          SHOW_WARNING = new_warn
          mark_settings_dirty()
        end

        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, "Setlist storage")

        -- ===== Setlist-Ordner (Puffer) =====
        if reaper.ImGui_InputText ~= nil then
          local changed_dir, nd = reaper.ImGui_InputText(ctx, "Setlist folder", INPUT.dir_set or "", 512)
          if changed_dir then INPUT.dir_set = nd; settings_needs_apply = true end
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Browse…##dir") then
          local d = browse_for_dir()
          if d then INPUT.dir_set = normalize_path(d); settings_needs_apply = true end
        end

        if reaper.ImGui_Button(ctx, "Use default") then
          INPUT.dir_set = DIR_SET_DEFAULT
          settings_needs_apply = true
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Open in Explorer/Finder") then
          local to_open = DIR_SET or DIR_SET_DEFAULT
          if reaper.CF_ShellExecute then
            reaper.CF_ShellExecute(to_open)
          else
            local cmd = is_windows() and ('start "" "'..to_open..'"') or ('open "'..to_open..'"')
            os.execute(cmd)
          end
        end

        -- ===== UI-Scale =====
        local _, newscale = SliderNumber("UI scale", UI_SCALE, 0.8, 2.0)
        if newscale and math.abs(newscale-UI_SCALE) > 1e-3 then
          UI_SCALE = newscale
          mark_settings_dirty()
          rebuild_fonts()
        end

        -- ===== Repair-Helper =====
        if reaper.ImGui_Button(ctx, "Repair missing entries by name") then
          scan_regions()
          for _, e in ipairs(setlist.entries) do
            if (not R(e.region_idx)) and e.name then
              local rr = R_by_name(e.name)
              if rr then e.region_idx = rr.idx end
            end
          end
        end
        reaper.ImGui_Text(ctx, "Tipp: Pfad auf Netzwerkfreigabe setzen für A/B Sync")

        -- ===== Apply & Save =====
        reaper.ImGui_Separator(ctx)
        if settings_needs_apply then
          reaper.ImGui_Text(ctx, "Pending changes: not applied")
        else
          reaper.ImGui_Text(ctx, "Settings are up to date")
        end

        if reaper.ImGui_Button(ctx, "Apply") then
          -- Übernehme Puffer → Live-Variablen
          if INPUT.set_name and INPUT.set_name ~= "" then
            setlist.name = INPUT.set_name
          end

          if INPUT.status_path and INPUT.status_path ~= "" and INPUT.status_path ~= PATH_STATUS then
            PATH_STATUS = INPUT.status_path
          end

          if INPUT.dir_set and INPUT.dir_set ~= "" and INPUT.dir_set ~= DIR_SET then
            DIR_SET = normalize_path(INPUT.dir_set)
            ensure_dir(DIR_SET)
            save_prefs()
            refresh_files()
          end

          mark_settings_dirty()
          save_settings(true) -- sofort sichern
          settings_needs_apply = false
        end

        reaper.ImGui_SameLine(ctx, 0, math.floor(12*UI_SCALE))
        if reaper.ImGui_Button(ctx, "Save Settings") then
          save_settings(true)
          reaper.MB("Settings saved.", "Setlist Manager", 0)
        end

        reaper.ImGui_EndMenu(ctx)
      end
      if reaper.ImGui_BeginMenu(ctx, "Help") then
        if reaper.ImGui_MenuItem(ctx, "Quick Start") then show_help_quick = true end
        if reaper.ImGui_MenuItem(ctx, "Shortcuts")  then show_help_keys  = true end
        if reaper.ImGui_MenuItem(ctx, "About & Support") then show_help_about = true end
        if reaper.ImGui_MenuItem(ctx, "Diagnostics") then show_help_diag = true end
        if reaper.ImGui_MenuItem(ctx, "Show disclaimer now") then show_warning_pending = true end
        reaper.ImGui_EndMenu(ctx)
      end
      reaper.ImGui_EndMenuBar(ctx)
    end

    toolbar()
    if mode=="EDIT" then panel_edit() else panel_show() end
    draw_help_popups()
    hotkeys_in_frame()

    reaper.ImGui_End(ctx)
  end
  pop_theme()

  if not open then
    save_settings(true)
    return
  end

  -- >>> FIX-BLOCK: Falls schon gestoppt wurde und Continue AUS ist,
  --                aber der Cursor am Regionsende steht → still zur nächsten Region springen.
  do
    if not playing and #setlist.entries > 0 then
      local e = setlist.entries[current]
      if e and e.continue == false then
        local r = R(e.region_idx) or R_by_name(e.name)
        if r then
          local pos = (reaper.GetCursorPosition and reaper.GetCursorPosition()) or (reaper.GetPlayPosition() or 0)
          if pos >= (r.fin - TIME_EPS) and current < #setlist.entries then
            goto_i(current + 1, false) -- selektieren & Cursor setzen, kein Autoplay
          end
        end
      end
    end
  end

  engine()
  status_write()
  
  if settings_dirty then save_settings(false) end
  return open, playing
end

local function main()
  local ok, open, playing = pcall(run_main_logic)
  if not ok then
    reaper.ShowConsoleMsg("Setlist Manager Error: " .. tostring(open) .. "\n")
    open = true -- Keep running even if error happened
    playing = select(1, get_play_state())
  end

  if playing then
    last_play_pos = reaper.GetPlayPosition() or 0
  else
    last_play_pos = (reaper.GetCursorPosition and reaper.GetCursorPosition()) or 0
  end

  if not open then return end
  reaper.defer(main)
end





-- ============================================================
-- KAPITEL 11 — INIT
-- ============================================================

load_settings()
ensure_dir(DIR_SET)
refresh_files()
scan_regions()
rebuild_fonts()
show_warning_pending = SHOW_WARNING

-- NEU: sicherstellen, dass die Edit-Puffer aus den aktuellen Werten gefüllt sind
INPUT.status_path = PATH_STATUS or (PATH_STATUS_DEFAULT)
INPUT.dir_set     = DIR_SET or DIR_SET_DEFAULT
INPUT.set_name    = setlist.name or "My Set"
settings_needs_apply = false

reaper.defer(main)
