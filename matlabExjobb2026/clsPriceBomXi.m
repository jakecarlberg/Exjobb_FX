% Class for price bond

classdef clsPriceBomXi < handle
   properties
      iCurBOM          = 0   %
      firstDate        = 0   % 
      KDates           = []  % Cash flows dates
      nItems           = []  % Number of items
      iCurXi           = []  % Cash flow currencies
      iXip             = []  % This is the position in the xiP vector
   end
   
   methods
      
      function pb = clsPriceBomXi(iCurBOM, firstDate, KDates, nItems, iXip, iCurXi)
        pb.iCurBOM     = iCurBOM;
        pb.firstDate   = firstDate;
        pb.KDates      = KDates;
        pb.nItems      = nItems;
        pb.iXip        = iXip;
        pb.iCurXi      = iCurXi;
      end % clsPriceBond constructor
      
      function [p, g, H] = price(pb, dm, dc)
        M = length(dm.dates);
        p = zeros(M,1);
        g = cell(M,1);
        H = cell(M,1);
        lDate = min([max(pb.KDates) dm.dates(end)]);
        fDate = max([pb.firstDate dm.dates(1)]);
        iFirstDate = dm.indAllDates(fDate-dm.dates(1)+1);
        iLastDate = dm.indAllDates(lDate-dm.dates(1)+1);
        N = size(dc.xi,2);
        for i=iFirstDate:iLastDate
          ind = find(pb.KDates>dm.dates(i));          
          gi = [];
          gVal = [];
          Hi = [];
          Hj = [];
          HVal = [];
%           fullH = zeros(N,N);
          for j=1:length(ind)
            jj = ind(j);
            f = dm.fx{pb.iCurXi(jj), pb.iCurBOM}(i);
            indp = dc.xiP2xiInd(pb.iXip(jj));
            indf = dc.xif2xiInd(pb.iCurXi(jj), pb.iCurBOM);
            p(i) = p(i) + dc.xi(i,indf) * pb.nItems(jj) * dc.xi(i,indp);


            if (nargout >= 2)
              gi = [gi ; indf ; indp];
              gVal = [gVal ; pb.nItems(jj) * dc.xi(i,indp) ; dc.xi(i,indf) * pb.nItems(jj)];
            end
           
            if (nargout >= 3)
              Hi = [Hi ; indf ; indp];
              Hj = [Hj ; indp ; indf];
              HVal = [HVal ; pb.nItems(jj) ; pb.nItems(jj)];
            end

          end
          if (nargout >= 2)
            g{i} = sparse(gi, ones(size(gi)), gVal, N, 1);
          end
          if (nargout >= 3)
            H{i} = sparse(Hi, Hj, HVal, N, N);
          end
        end
      end

      function [D] = dividends(pb, dm, dc)
        Nc = length(dm.cName);
        indCF = ((pb.KDates >= dm.dates(1)) & (pb.KDates <= dm.dates(end)));
        fDate = dm.dates(1);
        D = cell(Nc, 1);
        for k=1:Nc
          ind = find(indCF & pb.iCurXi == k);
          if (~isempty(ind))
            Di = [];
            Dj = [];
            DVal = [];
            for j = 1:length(ind)
              jj = ind(j);
              indp = dc.xiP2xiInd(pb.iXip(jj));
              iDate = dm.indAllDates(pb.KDates(jj)-fDate+1);
              
              Di = [Di ; iDate];
              Dj = [Dj ; 1];
              DVal = [DVal ; pb.nItems(jj) * dc.xi(iDate,indp)];

            end
            D{k} = sparse(Di, Dj, DVal);
          end
        end

      end

      function [iCurPrice] = priceCurrency(obj)
        iCurPrice = obj.iCurBOM;
      end
      
   end
   
   methods (Access = 'private') % Access by class members only
   end
end % classdef
