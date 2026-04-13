% Class for price bond

classdef clsPriceBond < handle
   properties
      iCurBond         = 0   %
      firstDate        = 0   % 
      cfDates          = []  % Cash flows dates
      cf               = []  % Cash flows
      iCurCf           = []  % Cash flow currencies
   end
   
   methods
      
      function pb = clsPriceBond(iCurBond, firstDate, cfDates, cf, iCurCf)
        pb.iCurBond     = iCurBond;
        pb.firstDate    = firstDate;
        pb.cfDates      = cfDates;
        pb.cf           = cf;
        pb.iCurCf       = iCurCf;
      end % clsPriceBond constructor
      
      function [p, g, H] = price(pb, dm, dc)
        M = length(dm.dates);
        p = zeros(M,1);
        g = cell(M,1);
        H = cell(M,1);
        lDate = min([max(pb.cfDates) dm.dates(end)]);
        fDate = max([pb.firstDate dm.dates(1)]);
        iFirstDate = dm.indAllDates(fDate-dm.dates(1)+1);
        iLastDate = dm.indAllDates(lDate-dm.dates(1)+1);
        N = size(dc.xi,2);
        for i=iFirstDate:iLastDate
          ind = find(pb.cfDates>dm.dates(i));          
%           ind = find(pb.cfDates>=dm.dates(i));          
          gi = [];
          gVal = [];
          Hi = [];
          Hj = [];
          HVal = [];
%           fullH = zeros(N,N);
          for j=1:length(ind)
            jj = ind(j);
            f = dm.fx{pb.iCurCf(jj), pb.iCurBond}(i);
            t = pb.cfDates(jj)-dm.dates(i)+1;
            d = dm.d{pb.iCurCf(jj)}(i,t)*pb.cf(jj);
            p(i) = p(i) + f * d;
            indf = dc.xif2xiInd(pb.iCurCf(jj), pb.iCurBond);
            indPC = dc.xiI2xiInd{pb.iCurCf(jj)};
            nPC = length(indPC);
            if (nargout >= 2)
              gi = [gi ; indf ; indPC];
              dInterior = dm.negIntE{pb.iCurCf(jj)}(t, :)';
              gVal = [gVal ; d ; f*d*dInterior];
            end
           
            if (nargout >= 3)
              Hi = [Hi ; ones(nPC,1)*indf];
              Hj = [Hj ; indPC];
              HVal = [HVal ; d*dInterior];
              Hj = [Hj ; ones(nPC,1)*indf];
              Hi = [Hi ; indPC];
              HVal = [HVal ; d*dInterior];
              tmp = f*d*dInterior*dInterior';
              iInd = repmat(indPC', nPC, 1);
              jInd = repmat(indPC, 1, nPC);
              Hj = [Hj ; iInd(:)];
              Hi = [Hi ; jInd(:)];
              HVal = [HVal ; tmp(:)];
            end

%             fullH(indPC, indPC) = fullH(indPC, indPC) + tmp;
%             fullH(pb.iXif, indPC) = fullH(pb.iXif, indPC) + d*dInterior';
%             fullH(indPC, pb.iXif) = fullH(indPC, pb.iXif) + d*dInterior;
          end
          if (nargout >= 2)
            g{i} = sparse(gi, ones(size(gi)), gVal, N, 1);
          end
          if (nargout >= 3)
            H{i} = sparse(Hi, Hj, HVal, N, N);
          end
%           H2 = sparse(fullH);
%           sum(sum(abs(H{i}-H2)))
        end
      end

      function [D] = dividends(obj, dm, dc)
        Nc = length(dm.cName);
        indCF = ((obj.cfDates >= dm.dates(1)) & (obj.cfDates <= dm.dates(end)));
        fDate = dm.dates(1);
        D = cell(Nc, 1);
        for k=1:Nc
          ind = find(indCF & obj.iCurCf == k);
          if (~isempty(ind))
            D{k} = sparse(dm.indAllDates(obj.cfDates(ind)-fDate+1), ones(length(ind),1), obj.cf(ind));
          end
        end

      end

      function [iCurPrice] = priceCurrency(obj)
        iCurPrice = obj.iCurBond;
      end
      
   end
   
   methods (Access = 'private') % Access by class members only
   end
end % classdef
