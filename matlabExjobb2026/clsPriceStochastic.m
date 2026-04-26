% Class for stochastic price of components

classdef clsPriceStochastic < handle
   properties
      iCurXi           = 0   %
      iCurPrice        = 0   % 
      iXip             = 0   % This is the position in the xiP vector 
   end
   
   methods
      
      function obj = clsPriceStochastic(iCurXi, iCurPrice, iXip)
        obj.iCurPrice = iCurPrice;
        obj.iCurXi = iCurXi;
        obj.iXip = iXip;
      end % clsPriceStochastic constructor
      
      function [p, g, H] = price(obj, dm, dc)
        indf = dc.xif2xiInd(obj.iCurXi, obj.iCurPrice);
        indp = dc.xiP2xiInd(obj.iXip);
        p = dc.xi(:,indf) .* dc.xi(:,indp);
        M = length(dm.dates);
        g = cell(M,1);
        H = cell(M,1);        
        N = size(dc.xi,2);
        for i=1:M
          if (nargout >= 2)
            g{i} = sparse([indf ; indp], [1 ; 1], [dc.xi(i, indp) ; dc.xi(i, indf)], N, 1);
          end
          if (nargout >= 3)
            H{i} = sparse([indf ; indp], [indp ; indf], [1 ; 1], N, N);
          end
        end
      end
      
      function [g_i, H_i] = priceRowGH(obj, dm, dc, i)
        N = size(dc.xi, 2);
        indf = dc.xif2xiInd(obj.iCurXi, obj.iCurPrice);
        indp = dc.xiP2xiInd(obj.iXip);
        g_i = sparse([indf; indp], [1;1], [dc.xi(i,indp); dc.xi(i,indf)], N, 1);
        H_i = sparse([indf; indp], [indp; indf], [1;1], N, N);
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
