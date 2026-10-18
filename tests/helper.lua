-- Test helper (loaded by busted before every spec, see .busted).
--
-- Taxi.load() builds a fresh addon namespace the way WoW does: it reads
-- Taxi/Taxi.toc and runs every listed Lua file as loadfile(path)("Taxi", ns),
-- except the game-facing layers (Game\*, UI\*) and Core\Init.lua, which need
-- the WoW API. Run busted from the repo root (scripts/test.sh does this).

local TOC_PATH = "Taxi/Taxi.toc"

local SKIPPED = {
  "^Game\\",
  "^UI\\",
  "^Core\\Init%.lua$",
}

local function isSkipped(entry)
  for _, pattern in ipairs(SKIPPED) do
    if entry:find(pattern) then
      return true
    end
  end
  return false
end

local function listTocFiles()
  local f = assert(io.open(TOC_PATH, "r"))
  local files = {}
  for line in f:lines() do
    local entry = line:gsub("\r$", ""):match("^%s*(.-)%s*$")
    -- Blank lines and "## Field: value" / "# comment" lines are not files.
    if entry ~= "" and entry:sub(1, 1) ~= "#" then
      files[#files + 1] = entry
    end
  end
  f:close()
  return files
end

Taxi = {}

function Taxi.load()
  local ns = {}
  for _, entry in ipairs(listTocFiles()) do
    if not isSkipped(entry) then
      local path = "Taxi/" .. entry:gsub("\\", "/")
      local chunk = assert(loadfile(path))
      chunk("Taxi", ns)
    end
  end
  return ns
end
