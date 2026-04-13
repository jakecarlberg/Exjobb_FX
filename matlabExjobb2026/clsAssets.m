classdef clsAssets < handle
   properties
      assets = {};
      assetType = {};
      iCurAssets = []; % Currency for each asset
      indPriceInventory = []; % Contain both indPriceStochastic and indPriceDeterministic
      indPriceShrinkage = [];
      indManufactured = [];
      indBond = [];
   end
   properties (Dependent) % Values that are calculated
   end
   
   methods
      function obj = clsAssets()
      end % clsInstruments constructor
   end
   
   
   methods
      function [id] = add(obj, asset, assetType_)
        n = length(obj.assets)+1;
        obj.assets{n} = asset;
        obj.assetType{n} = assetType_;
        if (assetType_ == AssetType.itemInventory)
          id = length(obj.indPriceInventory)+1;
          obj.iCurAssets = [obj.iCurAssets asset.iCurPrice];
          obj.indPriceInventory(id) = n;
        elseif (assetType_ == AssetType.itemShrinkage)
          id = length(obj.indPriceShrinkage)+1;
          obj.iCurAssets = [obj.iCurAssets asset.iCurPrice];
          obj.indPriceShrinkage(id) = n;          
        elseif (assetType_ == AssetType.itemManufactured)
          id = length(obj.indManufactured)+1;
          obj.iCurAssets = [obj.iCurAssets asset.iCurBOM];
          obj.indManufactured(id) = n;
        elseif (assetType_ == AssetType.zeroCouponBond)
          id = length(obj.indBond)+1;
          obj.iCurAssets = [obj.iCurAssets asset.iCurBond];
          obj.indBond(id) = n;          
        end
      end

      function [p, g, H] = price(obj, dm, dc, activeAssets)
        N = length(obj.assets);
        if (nargin == 3)
          activeAssets = true(N,1);
        end
        M = length(dm.dates);
        p = zeros(M,N);
        g = cell(M,N);
        H = cell(M,N);
        ind = [obj.indPriceInventory obj.indPriceShrinkage obj.indManufactured obj.indBond];
        for j=1:length(ind)
          if (~activeAssets(j))
            continue;
          end
          o = obj.assets{ind(j)};
          if (nargout == 1)
            [p(:,j)] = o.price(dm, dc);
          elseif (nargout == 2)
            [p(:,j), g{:,j}] = o.price(dm, dc);
          elseif (nargout == 3)
            [p(:,j), g(:,j), H(:,j)] = o.price(dm, dc);            
          end
        end
      end

      function [D] = dividends(obj, dm, dc, activeAssets)
        N = length(obj.assets);
        M = length(dm.dates);
        Nc = length(dm.cName);
        if (nargin == 3)
          activeAssets = true(N,1);
        end

        iiD = cell(Nc, 1);
        jjD = cell(Nc, 1);
        Dv  = cell(Nc, 1);
        ind = [obj.indPriceInventory obj.indPriceShrinkage obj.indManufactured obj.indBond];
        for j=1:length(ind)
          if (~activeAssets(j))
            continue;
          end
          o = obj.assets{ind(j)};
          Di = o.dividends(dm, dc);
          for k=1:Nc
            if (~isempty(Di{k}))
              [ii, jj, v] = find(Di{k});
              iiD{k} = [iiD{k} ; ii];
              jjD{k} = [jjD{k} ; ones(size(ii))*j];
              Dv{k} = [Dv{k} ; v];
            end
          end
        end
        D = cell(Nc, 1);
        for k=1:Nc
          D{k} = sparse(iiD{k}, jjD{k}, Dv{k}, M, N);
        end
      end
      
      function [Ic] = pricingCurrency(obj)
        N = length(obj.assets);
        ind = [obj.indPriceInventory obj.indPriceShrinkage obj.indManufactured obj.indBond];
        Ic = zeros(N,1);
        for j=1:length(ind)
          o = obj.assets{ind(j)};
          [Ic(j)] = o.priceCurrency();
        end
      end
      

   end
   
   methods (Access = 'private') % Access by class members only

   end
end % classdef

