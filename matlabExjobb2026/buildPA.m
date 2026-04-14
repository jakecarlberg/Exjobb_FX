function [dp] = buildPA(dm, dc)

% buildPA generates sparse matrices for performance attribution
% M = number of time stages
% N = number of assets (items, shrinkage, BOM structures, zero coupon bonds)
% Nc = number of currencies
% hI0: initial inventory of assets, size [1, N]
% xBI: xBuyInventory, size [M, N] 
% xSI: xSellInventory, size [M, N]
% sBI: transaction cost BuyInventory, size [M, N] 
% sSI: transaction cost SellInventory, size [M, N]
% D{k}: dividend matrix for each currency k from assets, size [M, N]
% P: market price of assets, size [M, N]
% Pbar: theoretical price of assets, size [M, N]
% IC: price currency for each assets, size [N, 1]
% hC0: initial inventory of cash, size [1, Nc]
% xBC: xBuyCurrency - not yet implemented
% xSC: xSellCurrency - not yet implemented

M = length(dm.dates);

firstDate = dm.dates(1);
lastDate = dm.dates(end);

indAllDates = dm.indAllDates; % Quick mapping from date to index

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Model transactions and procurement


N = length(dc.assets.assets);

iiB = ones(N,1);
jjB = (1:N)';
xBv = ones(N,1)*NaN; % First row should not be used
sBv = ones(N,1)*NaN; % First row should not be used
iiS = ones(N,1);
jjS = (1:N)';
xSv = ones(N,1)*NaN; % First row should not be used
sSv = ones(N,1)*NaN; % First row should not be used

h0 = zeros(1,N);
Pbar = dc.assets.price(dm, dc);

for k=1:length(dc.itemNumbers)
  % Only consider dates within dm.dates

  % Model items in stock
  
  indPaRange = ((dc.s.entryDate>firstDate) & (dc.s.entryDate<=lastDate) & dc.s.itemNumber == dc.itemNumbers(k)); % Do not use values at t=0

  ind = find(indPaRange);
  if (length(ind) == 0)
    continue;
  end
  kk = k;
  h0(kk) = dc.s.newOnHandBalance(ind(1)) - dc.s.transactionQuantityBasicUM(ind(1));

  % Model buy variables
  % First compute the sum sB xB derived from each activity, then divide by xB to determine the average sB
  % Since both procurement (transactionType == 25) and negative shrinkage can affect the same row - by dividing with xB it gets correct since sB xB is in the PA model

  ind = find((dc.s.transactionQuantityBasicUM>0) & indPaRange);
  ii = indAllDates(dc.s.entryDate(ind)-firstDate+1);
  xBk = sparse(ii, 1, dc.s.transactionQuantityBasicUM(ind), M, 1);
  sBk = zeros(M,1); 
  
  % Inventory procurement
  ind = find(dc.s.stockTransactionType == 25 & indPaRange & dc.s.jPurchaseOrder ~= 0);
  PProcurement = dc.procurementPrices{k}.state(dm);
%   Pbar = dc.assets.assets{dc.assets.indPriceInventory(k)}.price(dm, dc);
  
  for i=1:length(ind)
    j = dc.s.jPurchaseOrder(ind(i));
    amount = dc.p.lineAmountOrderCurrency(j);
    iDate = indAllDates(dc.s.entryDate(ind(i))-firstDate+1);
    if (dc.p.dueDate(j)-firstDate+1 <= length(indAllDates))
      iDueDate = indAllDates(dc.p.dueDate(j)-firstDate+1);
    else
      iDueDate = -1;
    end

    jBond = dc.assets.indBond(dc.p.jBond(j));
    bond = dc.assets.assets{jBond};
    [PBond] = bond.price(dm, dc);
    
    amountNPV = amount*PBond(iDate);
    err = amountNPV - PProcurement(iDate) * dc.s.transactionQuantityBasicUM(ind(i));
    % Use relative tolerance: clsXiLastProcurement averages same-day orders,
    % so a small discrepancy is expected when multiple orders for the same
    % component land on the same date.
    relErr = abs(err) / max(abs(amountNPV), 1e-10);
    if (relErr > 1E-2)
      fprintf('%s %f %f (rel err %.4f%%)\n', datestr(dm.dates(iDate)), amountNPV, PProcurement(iDate) * dc.s.transactionQuantityBasicUM(ind(i)), 100*relErr);
      error('Cash paid not consistent with procurement price');
    end
    sBk(iDate) = sBk(iDate) + (PProcurement(iDate) - Pbar(iDate,kk)) * dc.s.transactionQuantityBasicUM(ind(i));
    % AP short position is handled by the AP bond loop below (dc.ap.jBond).
    % Procurement bonds (dc.p.jBond) are kept only for the pricing validation above.
  end
  
  [ii,jj,v] = find(xBk); % x contains sum of buy variables
  sBk(ii) = sBk(ii)./v;

  iiB = [iiB ; ii];
  jjB = [jjB ; ones(length(ii),1)*kk];
  xBv = [xBv ; v];
  sBv = [sBv ; sBk(ii)];
  
  % Model sell variables

  % Inventory sales -> Sell variables

  PSale = dc.salePrices{k}.state(dm);

  ind = find((dc.s.transactionQuantityBasicUM<0) & indPaRange);
  iDate = indAllDates(dc.s.entryDate(ind)-firstDate+1);
  xSk = sparse(iDate, 1, -dc.s.transactionQuantityBasicUM(ind), M, 1);
  sSk = zeros(M,1); 

  [ii,jj,v] = find(xSk); % x contains sum of sell variables

  iiS = [iiS ; ii];
  jjS = [jjS ; ones(length(ii),1)*kk];
  xSv = [xSv ; xSk(ii)];
  sSv = [sSv ; Pbar(ii,kk) - PSale(ii)];

  % Shrinkage
  kk = dc.assets.indPriceShrinkage(k);
  
  h0(kk) = 0;

  ind = find(dc.s.stockTransactionType == 90 & indPaRange);

  xBs = zeros(M, 1); xBs(1) = NaN;
  xSs = zeros(M, 1); xSs(1) = NaN;
  sBs = zeros(M, 1); sBs(1) = NaN;
  sSs = zeros(M, 1); sSs(1) = NaN;

  for i=1:length(ind)
    iDate = indAllDates(dc.s.entryDate(ind(i))-firstDate+1);
    buySell = dc.s.transactionQuantityBasicUM(ind(i));
    if (buySell>0)
      xSs(iDate) = xSs(iDate) + buySell;
      sSs(iDate) = sSs(iDate) - buySell*Pbar(iDate,k);
    elseif (buySell<0)
      xBs(iDate) = xBs(iDate) - buySell;
      sBs(iDate) = sBs(iDate) + -buySell*Pbar(iDate,k);
    end
  end

  [ii,jj,v] = find(xBs); % x contains sum of buy variables
  sBs(ii) = sBs(ii)./v;
  iiB = [iiB ; ii];
  jjB = [jjB ; ones(length(ii),1)*kk];
  xBv = [xBv ; v];
  sBv = [sBv ; sBs(ii)];
  
  [ii,jj,v] = find(xSs); % x contains sum of sell variables
  sSs(ii) = sSs(ii)./v;
  iiS = [iiS ; ii];
  jjS = [jjS ; ones(length(ii),1)*kk];
  xSv = [xSv ; v];
  sSv = [sSv ; sSs(ii)];

end

for k=1:length(dc.productNumbers)
  % Only consider dates within dm.dates

  % Model BOM

  ii = find(dc.sa.itemNumber == dc.productNumbers(k));
  if (length(ii) ~= 1)
    fprintf('Could not find a unique invoice for product %d\n', dc.productNumbers(i)); error('Exiting');
  end
  invoiceNumber = dc.sa.invoiceNumber(ii);

  jj = find(dc.a.transactionCode == 10 & dc.a.invoiceNumber == invoiceNumber);
  kk = find(dc.a.transactionCode == 20 & dc.a.invoiceNumber == invoiceNumber);
  if (length(jj) ~= 1 || length(kk) ~= 1)
    fprintf('Could not find accounts receiveable for invoice %d\n', invoiceNumber); error('Exiting');
  end
  
  if (dc.productOrderDate(k) > lastDate || dc.a.accountingDate(kk) <= firstDate)
    continue; % Product not active during performance attribution period - skip
  end

  
  kh = dc.assets.indManufactured(k);
  if (dc.productOrderDate(k) <= firstDate) % First row should not be used
    h0(kh) = 1;
  else
    h0(kh) = 0;
    
    iDate = indAllDates(dc.productOrderDate(k)-firstDate+1);
    
    % Buy product (BOM)
    iiB = [iiB ; iDate];
    jjB = [jjB ; kh];
    xBv = [xBv ; 1];
    sBv = [sBv ; -Pbar(iDate,kh)]; % Buys asset to price zero for BOM (this is the ex ante revenue)
  end
  
  if (dc.a.accountingDate(jj) <= lastDate) % Produciton of BOM has finished and delivered during PA period
    
    if (dc.a.accountingDate(jj) < dc.productOrderDate(k))
      fprintf('Product %s was ordered on date %s but delivered on date %s\n', dc.productNumberDictionary{dc.productNumbers(k)}, datestr(dc.productOrderDate(k)), datestr(dc.a.accountingDate(jj)));
    end
    
    iDate = indAllDates(dc.a.accountingDate(jj)-firstDate+1);
    jBond = dc.assets.indBond(dc.a.jBond(jj));
    iCurBond = dc.assets.assets{jBond}.iCurBond;
    iCurAsset = dc.assets.iCurAssets(kh);
    
    sellingPrice = dc.a.foreignCurrencyAmount(jj);

    % Sell product (BOM)
    iiS = [iiS ; iDate];
    jjS = [jjS ; kh];
    xSv = [xSv ; 1];
%     sSv = [sSv ; Pbar(iDate,kh) - sellingPrice*Pbar(iDate, jBond)*dm.fx{iCurBond, iCurAsset}(iDate)];
    sSv = [sSv ; 0]; % When it has zero value
    
    % Buy bond (cancel out selling of BOM)
    
    iiB = [iiB ; iDate];
    jjB = [jjB ; jBond];
    xBv = [xBv ; sellingPrice];
    sBv = [sBv ; 0];

    if (dc.a.accountingDate(kk) <= lastDate) % Bond matures - sell bond
      jDate = indAllDates(dc.a.accountingDate(kk)-firstDate+1);
      
      iiS = [iiS ; jDate];
      jjS = [jjS ; jBond];
      xSv = [xSv ; sellingPrice];
      sSv = [sSv ; 0];
      
    end
    
  end

end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% AP bonds: accounts payable (thesis Eq. 4.39)
% AP is a SHORT bond position: sell bond when AP is created (order placed),
% buy bond back when AP is settled (payment made).
% Note: in the simulated data, order date == delivery date, so these AP bonds
% span the same period as the procurement bonds above. In real data they differ.

apOrderNums = unique(dc.ap.invoiceNumber);
for i = 1:length(apOrderNums)
  jj = find(dc.ap.transactionCode == 10 & dc.ap.invoiceNumber == apOrderNums(i));
  kk = find(dc.ap.transactionCode == 20 & dc.ap.invoiceNumber == apOrderNums(i));

  if (isempty(jj) || isempty(kk) || dc.ap.jBond(jj) == 0), continue; end

  % Skip if AP is entirely outside the PA date range
  if (dc.ap.accountingDate(jj) > lastDate || dc.ap.accountingDate(kk) <= firstDate), continue; end

  jBond = dc.assets.indBond(dc.ap.jBond(jj));
  amount = dc.ap.foreignCurrencyAmount(jj);

  if (dc.ap.accountingDate(jj) > firstDate)
    iOrderDate = indAllDates(dc.ap.accountingDate(jj)-firstDate+1);
    % Sell bond: AP created (short position = liability to supplier)
    iiS = [iiS; iOrderDate];
    jjS = [jjS; jBond];
    xSv = [xSv; amount];
    sSv = [sSv; 0];
  else
    % AP was already open at PA start: short position from t=0
    h0(jBond) = -amount;
  end

  if (dc.ap.accountingDate(kk) <= lastDate)
    iPayDate = indAllDates(dc.ap.accountingDate(kk)-firstDate+1);
    % Buy bond back: AP settled (payment made to supplier)
    iiB = [iiB; iPayDate];
    jjB = [jjB; jBond];
    xBv = [xBv; amount];
    sBv = [sBv; 0];
  end
end

% Data for performance attribution (dp = data performance attribution)
dp.IC = dc.assets.pricingCurrency(); % Defines the set Ic = find(IC==c) for c = 1, ..., Nc


dp.hI0 = h0;
dp.xBI = sparse(iiB, jjB, xBv, M, N);
dp.xSI = sparse(iiS, jjS, xSv, M, N);
dp.sBI = sparse(iiB, jjB, sBv, M, N);
dp.sSI = sparse(iiS, jjS, sSv, M, N);
dp.Pbar = Pbar;
dp.P = dp.Pbar;
% dp.xiP = xiP;

Nc = length(dm.cName);
dp.hC0 = zeros(1, Nc); % No initial holding in cash

dp.D = cell(Nc, 1);
for k=1:Nc
  dp.D{k} = sparse([], [], [], M, N); % No dividends for inventory model
end

dp.D = dc.assets.dividends(dm, dc);

% p2 = assetdc.s.price(dm, dp);
% 
% sum(sum(abs(p2-dp.Pbar)))



