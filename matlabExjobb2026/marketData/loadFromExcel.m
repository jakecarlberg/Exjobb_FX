function [dates, ric, tenor, maturityDates, zeroRates] = loadFromExcel(fileName)

if verLessThan('matlab', '9.7') % Not clear when change was made, need to run next line at least for version 9.6
  d = readtable(fileName,'Sheet', 'Sheet1');
else  
  d = readtable(fileName,'Sheet', 'Sheet1','Format','auto');
end
dates = datenum(d{2:end,1});
M = length(dates);
N = size(d,2);
j=2;
ric = cell(N,1);
tenor = cell(N,1);
maturityDates = zeros(M,N);
zeroRates = ones(M,N)*NaN;

n = 0;
while j<size(d,2)
  if (strcmp(d{2,j},'The universe is not found.')) 
    j = j+1;
  else
    RIC = char(d.Properties.VariableDescriptions(j));
    if (strcmp(RIC(1:min(length(RIC), 24)), 'Original column heading:'))
      RIC = RIC(27:length(RIC)-1);
    end
    n = n+1;
    ric{n} = RIC;
    iBeg = 4;
    if (strcmp('OIS', RIC(4:6)))
      iBeg = 7;
    end
    tenor{n} = RIC(iBeg:length(RIC)-3);
    tmp = d{2:end,j+1};
    indz = ~strcmp('',tmp); 
    zeroRates(indz,n) = cellfun(@str2double, tmp(indz))/100;
    tmp = d{2:end,j};
    indd = ~(strcmp('#N/A',tmp) | strcmp('',tmp)); 
    maturityDates(indd,n) = dateInt2dateNum(cellfun(@str2double, tmp(indd)));

    % Fix missing maturity dates - not validated (Reuters could use modified following).
    ind = find(indz & ~indd);
    str = char(tenor(n));
    if (strcmp(str, 'ON'))
      maturityDates(ind,n) = busdate(dates(ind),1);
    elseif (strcmp(str, 'TN'))
      maturityDates(ind,n) = busdate(busdate(dates(ind),1),1);
    elseif (strcmp(str, 'SN'))
      maturityDates(ind,n) = busdate(busdate(busdate(dates(ind),1),1),1);
    else
      spotDate = busdate(busdate(dates(ind),1),1);
      if (strcmp(str, '1W'))
        maturityDates(ind,n) = spotDate+7;
      elseif (strcmp(str, '2W'))
        maturityDates(ind,n) = spotDate+2*7;
      else
        km = strfind(str, 'M');
        ky = strfind(str, 'Y');
        m = 0;
        if (~isempty(km) && ~isempty(ky))
          m = str2double(str(ky+1:km-1)) + str2double(str(1:ky-1))*12;
        elseif (~isempty(km) && isempty(ky))
          m = str2double(str(1:km-1));
        elseif (isempty(km) && ~isempty(ky))
          m = str2double(str(1:ky-1))*12;
        else
          error('Incorrect tenor');
        end
        maturityDates(ind,n) = datenum(year(spotDate), month(spotDate)+m, day(spotDate));
      end
    end
    j = j+2;
  end
end
N = n;
ric = ric(1:N);
tenor = tenor(1:N);
dates = dates(M:-1:1);
maturityDates = maturityDates(M:-1:1,1:N);
zeroRates = zeroRates(M:-1:1,1:N);

