function [itemNumbers] = modifyItemNumbers(itemNumbers)

itemNumbersOrg = itemNumbers;
[uItemNumbersOrg, iaOrg, icOrg] = unique(itemNumbers);
tmp = itemNumbers;

itemNumbers  = str2double(tmp);
ind = isnan(itemNumbers);
tmp(ind) = replace(tmp(ind), 'X', '');
itemNumbers(ind)  = str2double(tmp(ind));
ind = find(isnan(itemNumbers));
ii = find(contains(tmp(ind), 'AC1-'));
for i=1:length(ii)
  tmp{ind(ii(i))} = tmp{ind(ii(i))}(6:end);
end
ii = find(contains(tmp(ind), '-T15'));
for i=1:length(ii)
  tmp{ind(ii(i))} = [tmp{ind(ii(i))}(1:10) 15];
end
ii = find(contains(tmp(ind), '-'));
for i=1:length(ii)
  tmp{ind(ii(i))} = tmp{ind(ii(i))}(1:10);
end
itemNumbers(ind)  = str2double(tmp(ind));

[uItemNumbers, ia, ic] = unique(itemNumbers);
if (length(uItemNumbersOrg) ~= length(uItemNumbers))
  uItemNumbersOrgCount = full(sparse(icOrg, ones(size(icOrg)), ones(size(icOrg)), length(uItemNumbersOrg), 1));
  itemNumbersCount = uItemNumbersOrgCount(icOrg);
  uItemNumbersCount = full(sparse(ic, ones(size(ic)), ones(size(ic)), length(uItemNumbers), 1));
  itemNumbersCountNew = uItemNumbersCount(ic);
  ind = find(itemNumbersCount ~= itemNumbersCountNew);
  diffNameOrg = unique(itemNumbersOrg(ind))
  diffNameNew = unique(itemNumbers(ind))
  error('Created incorrect change of itemnumbers')
end
