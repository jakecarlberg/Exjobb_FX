function s = fmtNum(x, decimals)
% fmtNum  Format a number with thousand separators.
%   s = fmtNum(x)             -> integer with commas, e.g. 1,234,567
%   s = fmtNum(x, 2)          -> 2 decimals with commas, e.g. 1,234.57
%
%   Handles negatives, zeros, NaN, and numbers in the millions/billions.

if nargin < 2, decimals = 0; end

if isnan(x)
  s = 'NaN';
  return;
end

neg = x < 0;
x = abs(x);

% Split integer and fractional parts
intPart = floor(x);
fracPart = x - intPart;

% Format integer part with commas
intStr = sprintf('%.0f', intPart);
n = length(intStr);
if n > 3
  % Insert commas every 3 digits from the right
  pos = n - 3;
  while pos > 0
    intStr = [intStr(1:pos) ',' intStr(pos+1:end)];
    pos = pos - 3;
  end
end

if decimals > 0
  fracStr = sprintf(['%.' num2str(decimals) 'f'], fracPart);
  fracStr = fracStr(2:end);  % strip leading "0"
  s = [intStr fracStr];
else
  s = intStr;
end

if neg, s = ['-' s]; end

end
