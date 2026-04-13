% Class for Last Procured Price with interest rate

classdef clsXiLastProcurement < handle
   properties
      datesBuy         = []  % 
      datesPay         = []  %
      purchaseAmount   = []  % 
      purchaceQuantity = []  % 
      iCurPurchase     = []  % 
      iCurPrice        = 0   %
      
   end
   
   methods
      
      function obj = clsXiLastProcurement(datesBuy, datesPay, purchaseAmount, purchaceQuantity, iCurPurchase, iCurPrice)
        obj.datesBuy = datesBuy;
        obj.datesPay = datesPay;
        obj.purchaseAmount = purchaseAmount;
        obj.purchaceQuantity = purchaceQuantity;
        obj.iCurPurchase = iCurPurchase;
        obj.iCurPrice = iCurPrice;
      end % constructor
      
      function [xiP] = state(obj, dm)
        % Create price vector with most recent price from procurement for each date in PA
        % Deals with multiple procurements on same date, and procurements made before firstDate (to have prices in beginning)
        firstDate = dm.dates(1);
        lastDate = dm.dates(end);
        xiP = zeros(length(dm.dates),1);

        totalCost = 0;
        totalQuantity = 0;
        for i=1:length(obj.purchaceQuantity)
          if (obj.datesBuy(i) < firstDate)
            discountFactor = dm.d{obj.iCurPurchase(i)}(1, obj.datesPay(i) - obj.datesBuy(i) + 1);
            exchangeRate = dm.fx{obj.iCurPurchase(i), obj.iCurPrice}(1);
          elseif (obj.datesBuy(i) > lastDate)
            discountFactor = dm.d{obj.iCurPurchase(i)}(end, obj.datesPay(i) - obj.datesBuy(i) + 1);
            exchangeRate = dm.fx{obj.iCurPurchase(i), obj.iCurPrice}(end);
          else
            iDate = dm.indAllDates(obj.datesBuy(i)-firstDate+1);
            discountFactor = dm.d{obj.iCurPurchase(i)}(iDate, obj.datesPay(i) - obj.datesBuy(i) + 1);
            exchangeRate = dm.fx{obj.iCurPurchase(i), obj.iCurPrice}(iDate);
          end
          totalCost = totalCost + obj.purchaseAmount(i)*discountFactor*exchangeRate;
          totalQuantity = totalQuantity + obj.purchaceQuantity(i);
          if (i<length(obj.purchaceQuantity))
            if (obj.datesBuy(i) == obj.datesBuy(i+1))
              continue; % Need to add another procurement
            end
          end
          
          if (obj.datesBuy(i) < firstDate)
            iStartDate = 1;
          elseif (obj.datesBuy(i) > lastDate)
            break;
          else
            iStartDate = dm.indAllDates(obj.datesBuy(i)-firstDate+1);
          end
          
          price = totalCost/totalQuantity;
          totalCost = 0;
          totalQuantity = 0;

          if (i == length(obj.purchaceQuantity))
            iEndDate = length(dm.dates);
          elseif (obj.datesBuy(i+1) < firstDate)
            continue; % Before first date
          elseif (obj.datesBuy(i+1) > lastDate)
            iEndDate = length(dm.dates);
          else
            iEndDate = dm.indAllDates(obj.datesBuy(i+1)-firstDate+1)-1;
          end
          
          xiP(iStartDate:iEndDate) = price * cumprod([1 ; dm.R(iStartDate:iEndDate-1, obj.iCurPrice)]);
          
        end
      end     
   end
   
   methods (Access = 'private') % Access by class members only
   end
end % classdef
