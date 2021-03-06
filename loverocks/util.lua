local lfs = require 'lfs'
local T   = require 'loverocks.schema'
local log = require 'loverocks.log'

local util = {}

local function slurp_file(fname)
	local file, err = io.open(fname, 'r')
	assert(file, err)
	local s = file:read('*a')
	file:close()
	return s
end

local function slurp_dir(dir)
	local t = {}

	for f in lfs.dir(dir) do
		if f ~= "." and f ~= ".." then
			t[f] = assert(util.slurp(dir .. "/" .. f))
		end
	end

	return t
end

-- TODO: what about symlinks to dirs?
function util.is_dir(path)
	T(path, 'string')

	return lfs.attributes(path, 'mode') == 'directory'
end

function util.is_file(path)
	T(path, 'string')

	return lfs.attributes(path, 'mode') == 'file'
end

function util.slurp(path)
	T(path, 'string')

	local ftype, err = lfs.attributes(path, 'mode')
	if ftype == 'directory' then
		return slurp_dir(path)
	elseif ftype then
		return slurp_file(path)
	else
		return nil, err
	end
end

local function spit_file(str, dest)
	local file, ok, err
	log:fs("spit %s", dest)
	file, err = io.open(dest, "w")
	if not file then return nil, err end

	ok, err = file:write(str)
	if not ok then return nil, err end

	ok, err = file:close()
	if not ok then return nil, err end

	return true
end

local function spit_dir(tbl, dest)
	log:fs("mkdir %s", dest)
	if not util.is_dir(dest) then
		local ok, err = lfs.mkdir(dest)
		if not ok then return nil, err end
	end

	for f, s in pairs(tbl) do
		if f ~= "." and f ~= ".." then
			local ok, err = util.spit(s, dest .. "/" .. f)
			if not ok then return nil, err end
		end
	end

	return true
end

-- Keep getting the argument order mixed up
function util.spit(o, dest)
	T(o, T.sum('table', 'string'))
	T(dest, 'string')

	if type(o) == 'table' then
		return spit_dir(o, dest)
	else
		return assert(spit_file(o, dest))
	end
end

local function ls_dir(dir)
	local t = {}
	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then
			local file_or_dir = util.files(dir .. "/" .. entry)
			if type(file_or_dir) == 'table' then
				for _, file in ipairs(file_or_dir) do
					table.insert(t, file)
				end
			else
				table.insert(t, file_or_dir)
			end
		end
	end
	return t
end

local function ls_file(path)
	return path
end

function util.files(path)
	T(path, 'string')

	local ftype, err = lfs.attributes(path, 'mode')
	if ftype == 'directory' then
		return ls_dir(path)
	elseif ftype then
		return ls_file(path)
	else
		return nil, err
	end
end

function util.get_home()
	return (os.getenv("HOME") or os.getenv("USERPROFILE"))
end

function util.clean_path(path)
	T(path, 'string')

	if path:match("^%~/") then
		path = path:gsub("^%~/", util.get_home() .. "/")
	end
	if not path:match("^/") and   -- /my-file
	   not path:match("^%./") and -- ./my-file
	   not path:match("^%a:") then -- C:\my-file
		path = lfs.currentdir() .. "/" .. path
	end
	return path
end

function util.exists(path)
	T(path, 'string')

	local f, err = io.open(path, 'r')
	if f then
		f:close()
		return true
	end
	return nil, err
end

return util
