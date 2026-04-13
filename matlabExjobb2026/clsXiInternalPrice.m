% Class for Last Procured Price with interest rate

classdef clsXiInternalPrice < handle
   properties
      costingDate         = []  % 
      costingSum1         = []  %
      
   end
   
   methods
      
      function obj = clsXiInternalPrice(costingDate, costingSum1)
        obj.costingDate = costingDate;
        obj.costingSum1 = costingSum1;
      end % constructor
      
      function [xiP] = state(obj, dm)
        M = length(dm.dates);
        firstDate = dm.dates(1);
        lastDate = dm.dates(end);
        indAllDates = dm.indAllDates; % Quick mapping from date to index
        
        xiP = zeros(M,1);
        indPaRange = ((obj.costingDate>=firstDate) & (obj.costingDate<=lastDate));
        ind = find(indPaRange);
        ii = indAllDates(obj.costingDate(ind)-firstDate+1);
        if (isempty(ind))
          ind = find(obj.costingDate<=firstDate)
          xiP(:) = obj.costingSum1(ind(end));
          return;
%           hej = 1
        end
        if (ind(1) >= 2 && ii(1) >= 2)
          xiP(1:ii(1)-1) = obj.costingSum1(ind(1)-1);  
        end
        for i=1:length(ind)-1
          xiP(ii(i):ii(i+1)-1) = obj.costingSum1(ind(i));
        end
        xiP(ii(end):end) = obj.costingSum1(ind(end));

      end     
   end
   
   methods (Access = 'private') % Access by class members only
   end
end % classdef
