--[[
Aseprite APNG / Animated PNG importer script.

This is non-functional as of yet. At the moment implemented is the basic
chunk parser along with a handful of specific chunk parsers. The core
features that need to be implemented are:
  * CRC32 checksumming
    * Should be implementable from other GPL or MIT lua-only sources
    * Perhaps https://github.com/openresty/lua-nginx-module/blob/master/t/lib/CRC32.lua
  * DEFLATE decompression and compression
    * Should be implementable from other GPL or MIT lua-only sources
    * Perhaps https://github.com/SafeteeWoW/LibDeflate/blob/master/LibDeflate.lua
  * IDAT/fdAT reading from their specific color types and other
    compression/packing methods.

At the moment the importer uses the standard file open system to open a
particular PNG file. What it should do is:
  * Clear the palette and the image
  * Populate the palette in parsePLTE
  * Create new Aseprite frames for the IDAT frame and fdAT frames

--]]
--[[ Binary
Binary provides a few helper function for decoding and comparing bytes.
--]]
Binary = {}
function Binary.toInt(str, bigendian, signed) -- use length of string to determine 8,16,32,64 bits
  if str == nil then return nil end
  local t={str:byte(1,-1)}
  if bigendian == true then
    local tt={}
    for k=1,#t do
        tt[#t-k+1]=t[k]
    end
    t=tt
  end
  local n=0
  for k=1,#t do
    n=n+t[k]*2^((k-1)*8)
  end
  if signed then
    n = (n > 2^(#t*8-1) -1) and (n - 2^(#t*8)) or n
  end
  return n
end
function Binary.compareByte(a, b)
  if string.byte(a) == string.byte(b) then
    return true
  end
  return false
end
function Binary.compare(a, b)
  if string.len(a) ~= string.len(b) then
    return false
  end
  for i = 1, #a do
    if Binary.compareByte(a:sub(i,i), b:sub(i,i)) ~= true then
      return false
    end
  end
  return true
end
--[[ Err / Error
The Err type and helper creator Error(type, msg) provide an interface for
managing errors during the script's functioning.
--]]
local E = {
  EOF = 1,
  BAD_CHUNK_LENGTH = 2,
  NOT_PNG = 3,
  CHUNK_ORDER_ERROR = 4,
  BAD_IHDR_LENGTH = 5,
  UNSUPPORTED_COMPRESSION_METHOD = 6,
  UNSUPPORTED_FILTER_METHOD = 7,
  INVALID_INTERLACE_METHOD = 8,
  NEGATIVE_DIMENSIONS = 9,
  DIMENSION_OVERFLOW = 10,
  UNSUPPORTED_CB = 11,
  BAD_PLTE_LENGTH = 12,
  PLTE_COLOR_TYPE_MISMATCH = 13,
  BAD_IEND_LENGTH = 14,
  strings = {
    "EOF",
    "BAD_CHUNK_LENGTH",
    "NOT_PNG",
    "CHUNK_ORDER_ERROR",
    "BAD_IHDR_LENGTH",
    "UNSUPPORTED_COMPRESSION_METHOD",
    "UNSUPPORTED_FILTER_METHOD",
    "INVALID_INTERLACE_METHOD",
    "NEGATIVE_DIMENSIONS",
    "DIMENSION_OVERFLOW",
    "UNSUPPORTED_CB",
    "BAD_PLTE_LENGTH",
    "PLTE_COLOR_TYPE_MISMATCH",
    "BAD_IEND_LENGTH"
  }
}
local Err = {
}
Err.__index = Err
function Err:new(t, m)
  local err = {}
  err.t = t
  err.m = m
  setmetatable(err, Err)
  return err
end
function Err:string()
  if self.m ~= nil then
    return E.strings[self.t] .. ": " .. self.m
  end
  return E.strings[self.t]
end
function Error(t, m)
  return Err:new(t, m)
end

--[[ Reader
The Reader is the state machine that is responsible for decoding an APNG
file into the active Aseprite sprite.
--]]
local pngHeader = "\x89PNG\r\n\x1a\n"
local INTERLACE = {
  NONE = 0,
  ADAM7 = 1
}
local CT = {
  GRAYSCALE = 0,
  TRUECOLOR = 2,
  PALETTED = 3,
  GRAYSCALE_ALPHA = 4,
  TRUECOLOR_ALPHA = 6
}
local CB = {
  INVALID = 0,
  G1 = 1,
  G2 = 2,
  G4 = 3,
  G8 = 4,
  GA8 = 5,
  TC8 = 6,
  P1 = 7,
  P2 = 8,
  P4 = 9,
  P8 = 10,
  TCA8 = 11,
  G16 = 12,
  GA16 = 13,
  TC16 = 14,
  TCA16 = 15
}

Stages = {
  Start = 0,
  SeenIHDR = 1,
  SeenPLTE = 2,
  SeentRNS = 3,
  SeenacTL = 4,
  SeenIDAT = 5,
  SeenIEND = 6
}
Reader = {
  -- crc = crc32.NewIEEE(),
  file = nil,          -- file reader from io
  frame_index = 0,     -- frame index we are currently reading
  buffer = {},         -- temp buffer for reading chunks
  stage = 0,           -- stage we are in as per Stages
  interlace = 0,
}
Reader.__index = Reader
function Reader:new(o)
  local rdr = {}
  setmetatable(rdr, Reader)
  rdr.file = o.file
  rdr.stage = 0
  rdr.interlace = 0
  rdr.frame_index = 0
  rdr.buffer = {}
  return rdr
end

function Reader:decode()
  local err = self:checkHeader()
  if err ~= nil then
    return err
  end
  while self.stage ~= Stages.SeenIEND do
    err = self:parseChunk()
    if err ~= nil then
      return err
    end
  end
  return err
end

function Reader:checkHeader()
  self.buffer = self.file:read(8)
  if self.buffer == nil then return Error(E.EOF) end
  if Binary.compare(self.buffer, pngHeader) ~= true then
    return Error(E.NOT_PNG)
  end
  return nil
end

function Reader:parseChunk()
  -- Reader length and chunk type.
  self.buffer = self.file:read(8)
  if type(self.buffer) == "table" then
    return Error(E.EOF)
  end
  local length = Binary.toInt(string.sub(self.buffer, 1, 4), true, false)
  -- self:clearChecksum()
  -- self:writeChecksum(bytes)
  local chunk = string.sub(self.buffer, 5, 8)
  if chunk == "IHDR" then
    if self.stage ~= Stages.Start then
      return Error(E.CHUNK_ORDER_ERROR)
    end
    self.stage = Stages.SeenIHDR
    return self:parseIHDR(length)
  elseif chunk == "PLTE" then
    if self.stage ~= Stages.SeenIHDR then
      return Error(E.CHUNK_ORDER_ERROR)
    end
    self.stage = Stages.SeenPLTE
    return self:parsePLTE(length)
  elseif chunk == "tRNS" then
  elseif chunk == "acTL" then
  elseif chunk == "fcTL" then
  elseif chunk == "fdAT" then
  elseif chunk == "IDAT" then
    self.stage = Stages.SeenIDAT
  elseif chunk == "IEND" then
    if self.stage < Stages.SeenIDAT then
      return Error(E.CHUNK_ORDER_ERROR)
    end
    self.stage = Stages.SeenIEND
    return self:parseIEND()
  else
  end
  if err ~= nil then
    return err
  end

  if length > 0x7ffffffff then
    return Error(E.BAD_CHUNK_LENGTH)
  end
  while length > 0 do
    bytes = self.file:read(length)
    if not bytes then return Error(E.EOF) end
    -- self:writeChecksum(bytes)
    length = length - #bytes
  end
  return self:verifyChecksum()
end

function Reader:parseIHDR(length)
  if length ~= 13 then
    return Error(E.BAD_IHDR_LENGTH)
  end
  self.buffer = self.file:read(13)
  if not self.buffer then return Error(E.EOF) end
  -- self:writeChecksum(bytes)
  if Binary.toInt(self.buffer:sub(11,11), true, false) ~= 0 then
    return Error(E.UNSUPPORTED_COMPRESSION_METHOD)
  end
  if Binary.toInt(self.buffer:sub(12,12), true, false) ~= 0 then
    return Error(E.UNSUPPORTED_FILTER_METHOD)
  end
  local int = Binary.toInt(self.buffer:sub(13,13), true, false)
  if int ~= INTERLACE.NONE and int ~= INTERLACE.ADAM7 then
    return Error(E.INVALID_INTERLACE_METHOD)
  end
  self.interlace = int

  local width = Binary.toInt(self.buffer:sub(1,4), true, false)
  local height = Binary.toInt(self.buffer:sub(5,8), true, false)
  if width <= 0 or height <= 0 then
    return Error(E.NEGATIVE_DIMENSIONS)
  end
  local pixels = width * height
  -- Restrict up to 8 bytes per pixel
  if pixels ~= (pixels*8)/8 then
    return Error(E.DIMENSION_OVERFLOW)
  end
  self.cb = CB.INVALID
  self.depth = Binary.toInt(self.buffer:sub(9,9), true, true)
  local ct = Binary.toInt(self.buffer:sub(10,10), true, true)
  if self.depth == 1 then
    if ct == CT.GRAYSCALE then
      self.cb = CB.G1
    elseif ct == cT.PALETTED then
      self.cb = CB.P1
    end
  elseif self.depth == 2 then
    if ct == CT.GRAYSCALE then
      self.cb = CB.G2
    elseif ct == CT.PALETTED then
      self.cb = CB.P2
    end
  elseif self.depth == 4 then
    if ct == CT.GRAYSCALE then
      self.cb = CB.G4
    elseif ct == CT.PALETTED then
      self.cb = CB.P4
    end
  elseif self.depth == 8 then
    if ct == CT.GRAYSCALE then
      self.cb = CB.G8
    elseif ct == CT.TRUECOLOR then
      self.cb = CB.TC8
    elseif ct == CT.PALETTED then
      self.cb = CB.P8
    elseif ct == CT.GRAYSCALE_ALPHA then
      self.cb = CB.GA8
    elseif ct == CT.TRUECOLOR_ALPHA then
      self.cb = CB.TCA8
    end
  elseif self.depth == 16 then
    if ct == CT.GRAYSCALE then
      self.cb = CB.G16
    elseif ct == CT.TRUECOLOR then
      self.cb = CB.TC16
    elseif ct == CT.GRAYSCALE_ALPHA then
      self.cb = CB.GA16
    elseif ct == CT.TRUECOLOR_ALPHA then
      self.cb = CB.TCA16
    end
  end
  if self.cb == CB.INVALID then
    return Error(E.UNSUPPORTED_CB)
  end
  -- Could set width & height here
  return self:verifyChecksum()
end

function Reader:parsePLTE(length)
  palettes = length / 3
  if (length % 3) ~= 0 or palettes <= 0 or palettes > 256 or palettes > 1<<self.depth then
    return Error(E.BAD_PLTE_LENGTH)
  end
  self.buffer = self.file:read(3 * palettes)
  if not self.buffer then return Error(E.EOF) end
  -- self:writeChecksum(bytes)
  if self.cb == CB.P1 or self.cb == CB.P2 or self.cb == CB.P4 or self.cb == CB.P8 then
    -- TODO: create palette here
  elseif self.cb == CB.TC8 or self.cb == CB.TCA8 or self.cb == CB.TC16 or self.cb == CB.TCA16 then
    -- PLTE chunk is optional for TrueColor and TrueColorAlpha
  else
    return Error(E.PLTE_COLOR_TYPE_MISMATCH)
  end
  return self:verifyChecksum()
end

function Reader:parseIEND(length) 
  if length ~= nil then
    return Error(E.BAD_IEND_LENGTH)
  end
  return self:verifyChecksum()
end

function Reader:verifyChecksum()
  self.file:read(4)
  return nil
end

--! Script Body !--
-- Load our PNG so we can get a base idea for setup.
app.command.OpenFile()
local sprite = app.activeSprite
-- From here we can read sprite.filename into our APNG reader.
local rdr = Reader:new{file = io.open(sprite.filename, "rb")}
local err = rdr:decode()
if err ~= nil then
  app.alert(err:string())
end
