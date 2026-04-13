function [itemNumbersInd, itemNumbersSorted, newItemNumbersInd] = indexItemNumbers(itemNumbersInd, itemNumbersSorted, newItemNumbers)

if (~iscell(newItemNumbers))
  ind = isnan(newItemNumbers);  
  tmp = newItemNumbers;
  newItemNumbers = cell(size(tmp));
  for i=1:length(tmp)
    newItemNumbers(i) = {num2str(tmp(i), '%010.0f')};
  end
  newItemNumbers(ind) = {''};
end

nOld = length(itemNumbersSorted);
nNew = length(newItemNumbers);

tmp = [itemNumbersSorted ; newItemNumbers];

[itemNumbersSorted, ia, ic] = unique(tmp);
itemNumbersIndOld = itemNumbersInd;

itemNumbersInd = ones(size(itemNumbersSorted))*NaN;
itemNumbersInd(ic(1:nOld)) = itemNumbersIndOld;
itemNumbersInd(isnan(itemNumbersInd)) = (nOld+1):length(itemNumbersSorted);

newItemNumbersInd = itemNumbersInd(ic((nOld+1):end));
