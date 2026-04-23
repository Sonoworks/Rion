function [p, fs] = readNX43WR(filename)
% calReadRion  Read a Rion NX-43WR waveform WAV file and return the signal
%              scaled to Pascals using the embedded calibration factor.
%
%   [p, fs] = calReadRion(filename)
%
%   Inputs:
%       filename  - path to WAV file recorded by a Rion NL-43/NL-53/NL-63
%                   with the NX-43WR waveform recording program.
%
%   Outputs:
%       p         - sound pressure in Pascals (Pa), Nx1 (mono) or Nx2 (stereo)
%       fs        - sample rate in Hz
%
%   Calibration source:
%       Rion NX-43WR WAV files contain a proprietary "rion" RIFF chunk that
%       embeds a Pa-per-raw-integer-count scaling factor as a little-endian
%       double at offset 0x24 within the chunk payload. This factor reflects
%       the actual ADC calibration for the specific instrument and selected
%       Rec. Lev. Range, and is the authoritative source of scaling.
%
%       Pa = raw_integer * scaleFactor
%          = (audioread_value * 2^(N-1)) * scaleFactor
%
%       This is more accurate than parsing the filename's "RRRdB" full scale
%       range token, which is approximate and does not capture per-instrument
%       calibration tolerance.
%
%   Verified empirically against 94 dB and 114 dB calibration tones at both
%   120 dB and 130 dB range settings; agreement within 0.1 dB.
%
%   Example:
%       [p, fs] = calReadRion('NL_0001_20260420_140130_130dB_1429_0224_ST0001.wav');
%       Lp = 20 * log10(rms(p) / 20e-6);
%
% -------------------------------------------------------------------------
%   MIT License
%
%   Copyright (c) 2026 Matt Torjussen <matt@sonoworks.co.uk>
%
%   Permission is hereby granted, free of charge, to any person obtaining a
%   copy of this software and associated documentation files (the "Software"),
%   to deal in the Software without restriction, including without limitation
%   the rights to use, copy, modify, merge, publish, distribute, sublicense,
%   and/or sell copies of the Software, and to permit persons to whom the
%   Software is furnished to do so, subject to the following conditions:
%
%   The above copyright notice and this permission notice shall be included
%   in all copies or substantial portions of the Software.
%
%   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
%   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
%   THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
%   OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
%   ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%   OTHER DEALINGS IN THE SOFTWARE.
% -------------------------------------------------------------------------

p_ref = 20e-6;  % reference sound pressure (Pa)

%  1. Locate the "rion" RIFF chunk and read the Pa-per-count factor 
%     at offset 0x24 within its payload.                            

fid = fopen(filename, 'rb');
if fid == -1
    error('calReadRion:cannotOpen', 'Cannot open file: %s', filename);
end
cleanup = onCleanup(@() fclose(fid));

% RIFF/WAVE header
riffID = fread(fid, 4, '*char')';
fread(fid, 1, 'uint32');           % RIFF size (skip)
waveID = fread(fid, 4, '*char')';
if ~strcmp(riffID, 'RIFF') || ~strcmp(waveID, 'WAVE')
    error('calReadRion:notWav', 'Not a RIFF/WAVE file: %s', filename);
end

% Walk top-level chunks looking for "rion"
scaleFactor = [];
while ~feof(fid)
    idBytes = fread(fid, 4, '*uint8');
    if numel(idBytes) < 4
        break
    end
    chunkID  = char(idBytes)';
    chunkLen = fread(fid, 1, 'uint32');
    if isempty(chunkLen)
        break
    end

    if strcmp(chunkID, 'rion')
        payloadStart = ftell(fid);
        fseek(fid, payloadStart + hex2dec('24'), 'bof');
        scaleFactor = fread(fid, 1, 'double');
        break
    end

    % Skip to next chunk (pad to even length per RIFF spec)
    skip = chunkLen + mod(chunkLen, 2);
    fseek(fid, skip, 'cof');
end

if isempty(scaleFactor)
    error('calReadRion:noRionChunk', ...
        ['No "rion" calibration chunk found in:\n  %s\n' ...
         'This file may not be a Rion NX-43WR recording, or the chunk ' ...
         'has been stripped by post-processing.'], filename);
end
if ~isfinite(scaleFactor) || scaleFactor <= 0
    error('calReadRion:invalidScale', ...
        'Invalid Pa-per-count scaling factor: %g', scaleFactor);
end

%  2. Read audio and metadata via audioread/audioinfo 
info  = audioinfo(filename);
fs    = info.SampleRate;
nbits = info.BitsPerSample;
xNorm = audioread(filename);   % normalised to [-1, 1]

% audioread divides raw integer by 2^(nbits-1), so undo that and apply
% Rion's per-count Pa scaling.
rawInt = xNorm * 2^(nbits - 1);
p      = rawInt * scaleFactor;


end