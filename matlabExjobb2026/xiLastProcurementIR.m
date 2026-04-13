function [xiP] = xiLastProcurementIR(dm, p, s)
% Create price vector with most recent price from procurement + short rate interest rate cost for each date in PA
% Deals with multiple procurements on same date, and procurements made before firstDate (to have prices in beginning)

ind = find(s.stockTransactionType == 25 & s.jPurchaseOrder>0);

j = s.jPurchaseOrder(ind);
purchaseAmount = p.lineAmountOrderCurrency(j);
datesBuy = s.entryDate(ind);
datesPay = p.dueDate(j);
purchaceQuantity = p.invoicedQuantityAlternateUM(j);
iCurPurchase = p.iCur(j);
iCurPrice = find(ismember(dm.cName, 'SEK'));

firstDate = dm.dates(1);
lastDate = dm.dates(end);
xiP = zeros(length(dm.dates),1);

totalCost = 0;
totalQuantity = 0;
for i=1:length(purchaceQuantity)
  if (datesBuy(i) < firstDate)
    discountFactor = dm.d{iCurPurchase(i)}(1, datesPay(i) - datesBuy(i) + 1);
    exchangeRate = dm.fx{iCurPurchase(i), iCurPrice}(1);
  elseif (datesBuy(i) > lastDate)
    discountFactor = dm.d{iCurPurchase(i)}(end, datesPay(i) - datesBuy(i) + 1);
    exchangeRate = dm.fx{iCurPurchase(i), iCurPrice}(end);
  else
    iDate = dm.indAllDates(datesBuy(i)-firstDate+1);
    discountFactor = dm.d{iCurPurchase(i)}(iDate, datesPay(i) - datesBuy(i) + 1);
    exchangeRate = dm.fx{iCurPurchase(i), iCurPrice}(iDate);
  end
  totalCost = totalCost + purchaseAmount(i)*discountFactor*exchangeRate;
  totalQuantity = totalQuantity + purchaceQuantity(i);
  if (i<length(purchaceQuantity))
    if (datesBuy(i) == datesBuy(i+1))
      continue; % Need to add another procurement
    end
  end

  if (datesBuy(i) < firstDate)
    iStartDate = 1;
  elseif (datesBuy(i) > lastDate)
    break;
  else
    iStartDate = dm.indAllDates(datesBuy(i)-firstDate+1);
  end

  price = totalCost/totalQuantity;
  totalCost = 0;
  totalQuantity = 0;

  if (i == length(purchaceQuantity))
    iEndDate = length(dm.dates);
  elseif (datesBuy(i+1) < firstDate)
    continue; % Before first date
  elseif (datesBuy(i+1) > lastDate)
    iEndDate = length(dm.dates);
  else
    iEndDate = dm.indAllDates(datesBuy(i+1)-firstDate+1)-1;
  end

  xiP(iStartDate:iEndDate) = price * cumprod([1 ; dm.R(iStartDate:iEndDate-1, iCurPrice)]);

end

