% Class for zero price of components (used to model shrinkage)

classdef clsPriceZero < handle
   properties
      iCurPrice        = 0   % 
   end
   
   methods
      
      function obj = clsPriceZero(iCurPrice)
        obj.iCurPrice = iCurPrice;
      end % constructor
      
      function [p, g, H] = price(obj, dm, dc)
        M = length(dm.dates);
        p = zeros(M,1);
        g = cell(M,1);
        H = cell(M,1);        
      end

      function [D] = dividends(obj, dm, dc)
        Nc = length(dm.cName);
        D = cell(Nc, 1);
      end
      

      function [iCurPrice] = priceCurrency(obj)
        iCurPrice = obj.iCurPrice;
      end
      
   end
   
   methods (Access = 'private') % Access by class members only
   end
end % classdef
