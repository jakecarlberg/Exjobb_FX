function periodDates = makeQuarterDates(d0, d1)
% makeQuarterDates  Quarter-end boundary dates covering [d0, d1].
%
%   periodDates = makeQuarterDates(d0, d1)
%
%   Returns a column vector starting at d0 and ending at d1, with
%   Mar 31 / Jun 30 / Sep 30 / Dec 31 inserted in between.

startYear = str2double(datestr(d0, 'yyyy'));
endYear   = str2double(datestr(d1, 'yyyy'));

periodDates = d0;
for yr = startYear:endYear
  for qEnd = [datenum(yr,3,31), datenum(yr,6,30), datenum(yr,9,30), datenum(yr,12,31)]
    if qEnd > d0 && qEnd < d1
      periodDates(end+1, 1) = qEnd; %#ok<AGROW>
    end
  end
end

if periodDates(end) < d1
  periodDates(end+1, 1) = d1;
end
end
