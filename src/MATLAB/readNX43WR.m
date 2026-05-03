function [p, fs, metadata] = readNX43WR(filename)
% readNX43WR  Read a Rion NX-43WR waveform WAV file and return the signal
%             scaled to Pascals using the embedded calibration factor.
%
%   [p, fs] = readNX43WR(filename)
%   [p, fs, metadata] = readNX43WR(filename)
%
%   Inputs:
%       filename  - path to WAV file recorded by a Rion NL-43/NL-53/NL-63
%                   with the NX-43WR waveform recording program.
%
%   Outputs:
%       p         - sound pressure in Pascals (Pa), Nx1 (mono) or Nx2 (stereo)
%       fs        - sample rate in Hz
%       metadata  - (optional) struct containing calibration and recording metadata:
%           .scaleFactor      - Pa per raw integer count (double)
%           .fullScaleRange   - full scale range (dB SPL) parsed from filename
%           .recordingTime    - datetime of recording start (MATLAB datetime)
%           .recordingDateStr - ISO 8601 date-time string (e.g. "20260420 140130")
%           .referenceUnits   - units string from rion chunk (usually "Pa")
%           .nBits            - bit depth (16 or 24)
%           .nChannels        - number of audio channels
%           .duration         - duration in seconds
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
%   Verified empirically against 94 dB and 114 dB calibration tones at both
%   120 dB and 130 dB range settings; agreement within 0.1 dB.
%
%   Example:
%       [p, fs, meta] = readNX43WR('NL_0001_20260420_140130_130dB_1429_0224_ST0001.wav');
%       Lp = 20 * log10(rms(p) / 20e-6);
%       disp(meta.recordingTime);
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
    metadata = struct();  % initialise metadata struct

    % ------------------------------------------------------------------ %
    %  1. Locate the "rion" RIFF chunk and extract calibration + metadata %
    % ------------------------------------------------------------------ %
    fid = fopen(filename, 'rb');
    if fid == -1
        error('readNX43WR:cannotOpen', 'Cannot open file: %s', filename);
    end
    cleanup = onCleanup(@() fclose(fid));

    % RIFF/WAVE header
    riffID = fread(fid, 4, '*char')';
    fread(fid, 1, 'uint32');           % RIFF size (skip)
    waveID = fread(fid, 4, '*char')';
    if ~strcmp(riffID, 'RIFF') || ~strcmp(waveID, 'WAVE')
        error('readNX43WR:notWav', 'Not a RIFF/WAVE file: %s', filename);
    end

    % Walk top-level chunks looking for "rion"
    scaleFactor = [];
    rionPayload = [];
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
            rionPayload = fread(fid, chunkLen, '*uint8');
            break
        end

        % Skip to next chunk (pad to even length per RIFF spec)
        skip = chunkLen + mod(chunkLen, 2);
        fseek(fid, skip, 'cof');
    end

    if isempty(rionPayload)
        error('readNX43WR:noRionChunk', ...
            ['No "rion" calibration chunk found in:\n  %s\n' ...
             'This file may not be a Rion NX-43WR recording, or the chunk ' ...
             'has been stripped by post-processing.'], filename);
    end

    % Extract scaleFactor at offset 0x24
    scaleFactor = typecast(rionPayload(37:44), 'double');  % 0x24 + 1 = 37 in 1-indexed
    if ~isfinite(scaleFactor) || scaleFactor <= 0
        error('readNX43WR:invalidScale', ...
            'Invalid Pa-per-count scaling factor: %g', scaleFactor);
    end
    metadata.scaleFactor = scaleFactor;

    % Extract reference units (usually "Pa") at offset 0x64 (about 16 bytes, space-padded)
    if numel(rionPayload) >= 100
        unitsBytes = rionPayload(101:116);  % 0x64 + 1 = 101
        unitsStr = strtrim(char(unitsBytes(:)'));
        unitsStr(unitsStr == 0) = [];
        if ~isempty(unitsStr)
            metadata.referenceUnits = unitsStr;
        end
    end

    % Extract full scale range string at offset 0x84 (about 16 bytes, space-padded)
    if numel(rionPayload) >= 132
        rangeBytes = rionPayload(133:148);  % 0x84 + 1 = 133
        rangeStr = strtrim(char(rangeBytes(:)'));
        rangeStr(rangeStr == 0) = [];
        if ~isempty(rangeStr)
            metadata.fullScaleRange = rangeStr;
        end
    end

    % Extract date-time string at offset 0xEF (14 bytes: YYYYMMDD HHMMSS)
    if numel(rionPayload) >= 240
        dateBytes = rionPayload(240:253);   % 0xEF + 1 = 240
        dateStr = strtrim(char(dateBytes(:)'));
        dateStr(dateStr == 0) = [];
        if length(dateStr) >= 14
            metadata.recordingDateStr = dateStr;
            % Parse to MATLAB datetime: YYYYMMDD HHMMSS -> datetime
            try
                yr = str2double(dateStr(1:4));
                mo = str2double(dateStr(5:6));
                dy = str2double(dateStr(7:8));
                hr = str2double(dateStr(10:11));
                mi = str2double(dateStr(12:13));
                sc = str2double(dateStr(14:15));
                metadata.recordingTime = datetime(yr, mo, dy, hr, mi, sc);
            catch
                % If parsing fails, leave recordingTime empty
            end
        end
    end

    % ------------------------------------------------------------------ %
    %  2. Read audio and metadata via audioread/audioinfo                 %
    % ------------------------------------------------------------------ %
    info  = audioinfo(filename);
    fs    = info.SampleRate;
    nbits = info.BitsPerSample;
    xNorm = audioread(filename);   % normalised to [-1, 1]

    nSamp = size(xNorm, 1);
    nCh   = size(xNorm, 2);
    duration = nSamp / fs;

    % Add audio metadata
    metadata.nBits    = nbits;
    metadata.nChannels = nCh;
    metadata.duration = duration;

    % audioread divides raw integer by 2^(nbits-1), so undo that and apply
    % Rion's per-count Pa scaling.
    rawInt = xNorm * 2^(nbits - 1);
    p      = rawInt * scaleFactor;

    % ------------------------------------------------------------------ %
    %  3. Confirmation output                                              %
    % ------------------------------------------------------------------ %
    p_ref = 20e-6;
    chNames = {'L', 'R', 'Ch3', 'Ch4'};

    fprintf('Read:           %s\n',   filename);
    fprintf('Sample rate:    %d Hz\n', fs);
    fprintf('Bit depth:      %d bit\n', nbits);
    fprintf('Channels:       %d\n',   nCh);
    fprintf('Duration:       %.3f s\n', duration);
    fprintf('Pa per count:   %.6e\n', scaleFactor);
    if isfield(metadata, 'recordingTime') && ~isempty(metadata.recordingTime)
        fprintf('Recording time: %s\n', string(metadata.recordingTime));
    elseif isfield(metadata, 'recordingDateStr')
        fprintf('Recording time: %s\n', metadata.recordingDateStr);
    end
    fprintf('\n');

    fprintf('%-16s', '');
    for ch = 1:nCh
        fprintf('%-14s', chNames{min(ch, numel(chNames))});
    end
    fprintf('\n');

    fprintf('%-16s', 'Peak (dB SPL):');
    for ch = 1:nCh
        fprintf('%-14.1f', 20 * log10(max(abs(p(:, ch))) / p_ref));
    end
    fprintf('\n');

    fprintf('%-16s', 'RMS (dB SPL):');
    for ch = 1:nCh
        fprintf('%-14.1f', 20 * log10(rms(p(:, ch)) / p_ref));
    end
    fprintf('\n');

end