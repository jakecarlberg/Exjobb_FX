% currencies = {'AUD', 'BGN', 'BWP', 'CAD', 'CHF', 'CLP', 'CNY', 'CZK', 'EUR', 'GBP', 'HKD', 'INR', 'JPY', 'KRW', 'MXN', 'NOK', 'PEN', 'PLN', 'RUB', 'SEK', 'SGD', 'THB', 'USD', 'ZAR'};
currencies = {'AUD', 'CAD', 'CHF', 'CLP', 'CNY', 'CZK', 'DKK', 'EUR', 'GBP', 'HKD', 'INR', 'JPY', 'KRW', 'MXN', 'NOK', 'PLN', 'RUB', 'SEK', 'SGD', 'THB', 'USD', 'ZAR'};
% BGN has no recent data
% BWP, PEN has no data
% CLP, INR has OIS data

firstDate = datenum(2019,1,1);
p = 1e2;

for i=5:5
% for i=1:length(currencies)
  currencyName = currencies(i);
  [dates, firstDates, lastDates, fH, ricAll, zH] = forwardRates(currencies(i), firstDate, p);
%   forwardRates;
  strTemp= char(strcat(currencies(i), int2str(p), '.mat'));
  save(strTemp,'dates', 'firstDates', 'lastDates', 'fH', 'ricAll', 'zH');
%   clear;
end

