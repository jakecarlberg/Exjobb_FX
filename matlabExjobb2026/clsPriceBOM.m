% Class for price bond

classdef clsPriceBOM < handle
   properties
      iCurBOM          = 0   %
      firstDate        = 0   % 
      KDates          = []  % Cash flows dates
      K               = []  % Cash flows
      iCurK           = []  % Cash flow currencies
   end
   
   methods
      
      function pb = clsPriceBOM(iCurBOM, firstDate, KDates, K, iCurK)
        pb.iCurBOM     = iCurBOM;
        pb.firstDate    = firstDate;
        pb.KDates      = KDates;
        pb.K           = K;
        pb.iCurK       = iCurK;
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
%           ind = find(pb.KDates>=dm.dates(i));          
          gi = [];
          gVal = [];
          Hi = [];
          Hj = [];
          HVal = [];
%           fullH = zeros(N,N);
          for j=1:length(ind)
            jj = ind(j);
            f = dm.fx{pb.iCurK(jj), pb.iCurBOM}(i);
            t = pb.KDates(jj)-dm.dates(i)+1;
            d = dm.d{pb.iCurK(jj)}(i,t)*pb.K(jj);
            p(i) = p(i) + f * d;
            indf = dc.xif2xiInd(pb.iCurK(jj), pb.iCurBOM);
            indPC = dc.xiI2xiInd{pb.iCurK(jj)};
            nPC = length(indPC);
            if (nargout >= 2)
              gi = [gi ; indf ; indPC];
              dInterior = dm.negIntE{pb.iCurK(jj)}(t, :)';
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

      function [g_i, H_i] = priceRowGH(pb, dm, dc, i)
        N = size(dc.xi, 2);
        gi=[]; gVal=[]; Hi=[]; Hj=[]; HVal=[];
        lDate = min([max(pb.KDates) dm.dates(end)]);
        fDate = max([pb.firstDate dm.dates(1)]);
        if dm.dates(i) >= fDate && dm.dates(i) <= lDate
          ind = find(pb.KDates > dm.dates(i));
          for j = 1:length(ind)
            jj = ind(j);
            f = dm.fx{pb.iCurK(jj), pb.iCurBOM}(i);
            t = pb.KDates(jj) - dm.dates(i) + 1;
            d = dm.d{pb.iCurK(jj)}(i,t) * pb.K(jj);
            indf = dc.xif2xiInd(pb.iCurK(jj), pb.iCurBOM);
            indPC = dc.xiI2xiInd{pb.iCurK(jj)};
            nPC = length(indPC);
            dInterior = dm.negIntE{pb.iCurK(jj)}(t,:)';
            gi = [gi; indf; indPC];
            gVal = [gVal; d; f*d*dInterior];
            Hi = [Hi; ones(nPC,1)*indf]; Hj = [Hj; indPC]; HVal = [HVal; d*dInterior];
            Hj = [Hj; ones(nPC,1)*indf]; Hi = [Hi; indPC]; HVal = [HVal; d*dInterior];
            tmp = f*d*dInterior*dInterior';
            iInd = repmat(indPC', nPC, 1); jInd = repmat(indPC, 1, nPC);
            Hj = [Hj; iInd(:)]; Hi = [Hi; jInd(:)]; HVal = [HVal; tmp(:)];
          end
        end
        if isempty(gi), g_i = sparse(N,1);
        else,           g_i = sparse(gi, ones(size(gi)), gVal, N, 1); end
        if isempty(Hi), H_i = sparse(N,N);
        else,           H_i = sparse(Hi, Hj, HVal, N, N); end
      end

      function [D] = dividends(obj, dm, dc)
        Nc = length(dm.cName);
        indCF = ((obj.KDates >= dm.dates(1)) & (obj.KDates <= dm.dates(end)));
        fDate = dm.dates(1);
        D = cell(Nc, 1);
        for k=1:Nc
          ind = find(indCF & obj.iCurK == k);
          if (~isempty(ind))
            D{k} = sparse(dm.indAllDates(obj.KDates(ind)-fDate+1), ones(length(ind),1), obj.K(ind));
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
