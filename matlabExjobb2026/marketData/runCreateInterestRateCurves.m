% Only the 9 currencies needed for the thesis simulation
currencies = {'AUD', 'CAD', 'CNY', 'EUR', 'GBP', 'INR', 'SEK', 'USD', 'ZAR'};

firstDate = datenum(2007,1,1);  % Change to 2005 when FX data is available
p = 1e2;

for i=1:length(currencies)
  currencyName = currencies(i);
  [dates, firstDates, lastDates, fH, ricAll, zH] = forwardRates(currencies(i), firstDate, p);
%   forwardRates;
  strTemp= char(strcat(currencies(i), int2str(p), '.mat'));
  save(strTemp,'dates', 'firstDates', 'lastDates', 'fH', 'ricAll', 'zH');
%   clear;
end

