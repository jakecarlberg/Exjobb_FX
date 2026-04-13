function [dates] = dateInt2dateNum(datesInt)

y = floor(datesInt/10000);
m = floor(mod(datesInt, 10000) / 100);
d = mod(datesInt, 100);
dates = datenum(y, m, d);


