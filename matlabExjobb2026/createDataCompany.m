function [dc] = createDataCompany(dm, settings)

dataFolder = settings.dataFolder;

if isfield(settings, 'curFunctional')
  curFunctional = settings.curFunctional;
else
  curFunctional = 'EUR';
end

load(fullfile(dataFolder, 'itemNumberDictionary'), 'itemNumberDictionary', 'productNumberDictionary');


if (isfield(settings, 'usedItemNumbersOrg'))
  usedItemNumbers = zeros(size(settings.usedItemNumbersOrg));
  for i=1:length(usedItemNumbers)
    usedItemNumbersStr = num2str(settings.usedItemNumbersOrg(i), '%010.0f');
    usedItemNumbers(i) = find(contains(itemNumberDictionary, usedItemNumbersStr));
  end
end

% Create Data Company structure, dc

nc = length(dm.cName);
M = length(dm.dates);

firstDate = dm.dates(1);
lastDate = dm.dates(end);

indAllDates = dm.indAllDates; % Quick mapping from date to index


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Procurement

load(fullfile(dataFolder, 'purchaseOrder'), 'p');

if (~exist('usedItemNumbers', 'var'))
  ind = false(size(p,1),1);
elseif (isempty(usedItemNumbers))
  ind = true(size(p,1),1);
else
  ind = false(size(p,1),1);
  for i=1:length(usedItemNumbers)
    ind = ind | (p.itemNumber == usedItemNumbers(i));
  end
end

p = p(ind,:);

p.iCur = zeros(size(p,1),1); % Index to currency

for i=1:size(p.iCur,1)
  iCur = find(ismember(dm.cName, p.currency(i)));
  if (isempty(iCur))
    error('Could not find currency');
  else
    p.iCur(i) = iCur;
  end
end


% writetable(p, "testInkop.xlsx");

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Costing

load(fullfile(dataFolder, 'costing'), 'c');

if (~exist('usedItemNumbers', 'var'))
  ind = false(size(c,1),1);
elseif (isempty(usedItemNumbers))
  ind = true(size(c,1),1);
else
  ind = false(size(c,1),1);
  for i=1:length(usedItemNumbers)
    ind = ind | (c.itemNumber == usedItemNumbers(i));
  end
end
c = c(ind,:);


% for i=1:length(xiP)
%   fprintf('%s %f\n', datestr(dm.dates(i)), xiP(i));
% end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Stock

% fileNameStock = "epiroc2023\Stock transactions sample LIU.xlsx";
% d = readtable(fileNameStock, "Sheet", "Sheet1");

load(fullfile(dataFolder, 'stockTransactions'), 's');

% d.orderNumber = str2double(d.orderNumber);

if (~exist('usedItemNumbers', 'var'))
  ind = false(size(s,1),1);
elseif (isempty(usedItemNumbers))
  ind = true(size(s,1),1);
else
  ind = false(size(s,1),1);
  for i=1:length(usedItemNumbers)
    ind = ind | (s.itemNumber == usedItemNumbers(i));
  end
end

s = s(ind, :);


% Find payment corresponding to procurement
ind = find(s.stockTransactionType == 25); % Procurement


s.jPurchaseOrder = zeros(size(s,1),1); % Index to purchase order on row (in p)
p.jStockTransaction = zeros(size(p,1),1); % Index to stock transaction on row (in s)
for i=1:length(ind)
  j = find(p.purchaseOrderNumber == s.orderNumber(ind(i)));
  if (isempty(j))
    fprintf('For item %s, purchase order %d for stock entry on date %s was not found', string(itemNumberDictionary(s.itemNumber(ind(i)))), s.orderNumber(ind(i)), datestr(s.entryDate(ind(i))));
    if (s.entryDate(ind(i)) >= firstDate && s.entryDate(ind(i)) <= lastDate)
      fprintf([' even though in data range [' datestr(firstDate) ', ' datestr(lastDate) ']\n']);
      % error('Missing date within performance attribution date range, exiting');
    else
      fprintf([' which is outside data range [' datestr(firstDate) ', ' datestr(lastDate) ']\n']);
    end
  elseif (length(j) > 1)
    error('Multiple purchase orders');
  else
    s.jPurchaseOrder(ind(i)) = j;
    p.jStockTransaction(j) = ind(i);
    if (s.transactionQuantityBasicUM(ind(i)) ~= p.invoicedQuantityAlternateUM(j))
      error('Order amount and delivered amount differ');
    end
    if (abs(s.entryDate(ind(i)) - p.accountingDate(j)) >= 10)
      error(['Stock date and accounting date differ ' datestr(s.entryDate(ind(i))) ' ' datestr(p.accountingDate(j))]);
    end
  end
end

% writetable(s, "testLager.xlsx");

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% BOM

load(fullfile(dataFolder, 'BOM'), 'b', 'productOrderDate');

if (~isfield(settings, 'usedProductNumbers'))
  ind = false(size(b,1),1);
elseif (isempty(settings.usedProductNumbers))
  ind = true(size(b,1),1);
else
  usedProductNumbers = zeros(size(settings.usedProductNumbers));
  for i=1:length(usedProductNumbers)
    usedProductNumbersStr = num2str(settings.usedProductNumbers(i), '%010.0f');
    usedProductNumbers(i) = find(contains(productNumberDictionary, usedProductNumbersStr));
  end
  ind = false(size(b,1),1);
  for i=1:length(usedProductNumbers)
    ind = ind | (b.product == usedProductNumbers(i));
  end
end

b = b(ind, :);


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Sales

load(fullfile(dataFolder, 'Sales'), 'sa');

sa.iCur = zeros(size(sa,1),1); % Index to currency

for i=1:size(sa.iCur,1)
  iCur = find(ismember(dm.cName, sa.currency(i)));
  if (isempty(iCur))
    error('Could not find currency');
  else
    sa.iCur(i) = iCur;
  end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Accounts receivable

load(fullfile(dataFolder, 'AccountsReceivable'), 'a');

a.iCur = zeros(size(a,1),1); % Index to currency

for i=1:size(a.iCur,1)
  iCur = find(ismember(dm.cName, a.currency(i)));
  if (isempty(iCur))
    error('Could not find currency');
  else
    a.iCur(i) = iCur;
  end
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Accounts payable
% Mirrors AR structure: transactionCode 10 = AP created (order placed),
%                       transactionCode 20 = AP settled (payment made)
% Per thesis Eq. 4.39: PAP = -C * exp(-rs(tau)*tau) * e  (negative = obligation)

load(fullfile(dataFolder, 'AccountsPayable'), 'ap');

ap.iCur = zeros(size(ap,1),1);

for i=1:size(ap.iCur,1)
  iCur = find(ismember(dm.cName, ap.currency(i)));
  if (isempty(iCur))
    error('Could not find currency');
  else
    ap.iCur(i) = iCur;
  end
end

dc.p = p;
dc.c = c;
dc.s = s;
dc.b = b;
dc.sa = sa;
dc.a = a;
dc.ap = ap;
dc.itemNumberDictionary = itemNumberDictionary;
dc.productNumberDictionary = productNumberDictionary;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Build universe
[dc.productNumbers, ia, ic] = unique([b.product]);
tmp = (1:length(dc.productNumbers))';
dc.b.iProduct = tmp(ic);

if (true) % Reduce number of itemNumbers to simplify debugging
  type = [ones(size(p.itemNumber)) ; ones(size(c.itemNumber))*2 ; ones(size(s.itemNumber))*3];
  [dc.itemNumbers, ia, ic] = unique([p.itemNumber ; c.itemNumber ; s.itemNumber]);
  tmp = (1:length(dc.itemNumbers))';
  dc.p.iItem = tmp(ic(type==1));
  dc.c.iItem = tmp(ic(type==2));
  dc.s.iItem = tmp(ic(type==3));
else
  type = [ones(size(p.itemNumber)) ; ones(size(c.itemNumber))*2 ; ones(size(s.itemNumber))*3 ; ones(size(b.componentNumber))*4];
  [dc.itemNumbers, ia, ic] = unique([p.itemNumber ; c.itemNumber ; s.itemNumber ; b.componentNumber]);
  tmp = (1:length(dc.itemNumbers))';
  dc.p.iItem = tmp(ic(type==1));
  dc.c.iItem = tmp(ic(type==2));
  dc.s.iItem = tmp(ic(type==3));
  dc.b.iComponent = tmp(ic(type==4));
end
dc.procurementPayments = find((s.entryDate>firstDate) & (s.entryDate<=lastDate) & (s.jPurchaseOrder>0));

% nItems = length(itemNumbers);
% nProducts = length(productNumbers);
% nPayments = length(procurementPayments);
% 
% nXip = nItems+nProducts;
% nx = 2*nItems+nProducts+nPayments;

% Create internal price list for each date in PA

dc.assets = clsAssets();
dc.randomVariables = clsRandomVariables();
dc.procurementPrices = cell(size(dc.itemNumbers));
dc.salePrices = cell(size(dc.itemNumbers));

% Hard coded modeling of the procurement, valuation and sales for the inventory
procurementPricing = 'LastProcurementPrice';
assetPricing = 'InternalPrice';
% assetPricing = 'LastProcurementPrice';
salePricing = 'InternalPrice';

internalPriceFlg = false(length(dc.itemNumbers), 1);
lastProcurementFlg = false(length(dc.itemNumbers), 1);

% Create realizations of random variables, which define xi-variables
for i=1:length(dc.itemNumbers)
  if (strcmp(procurementPricing, 'InternalPrice') || strcmp(assetPricing, 'InternalPrice') || strcmp(salePricing, 'InternalPrice'))
    ind = find(dc.c.itemNumber == dc.itemNumbers(i));
    if (~isempty(ind))
      internalPriceFlg(i) = true;
      rvInternalPrice = clsXiInternalPrice(dc.c.costingDate(ind), dc.c.CostingSum1(ind));
  %     PInternal = rvInternalPrice.state(dm);
    else
      internalPriceFlg(i) = false;
      ind = find(dc.b.componentNumber == dc.itemNumbers(i));
      if (isempty(ind))
        error('Could not find price for item in BOM structure');
      end
      rvInternalPrice = clsXiInternalPrice(dc.b.actualFinishDate(ind), dc.b.costPrice(ind));
    end
  end

  if (strcmp(procurementPricing, 'LastProcurementPrice') || strcmp(assetPricing, 'LastProcurementPrice') || strcmp(salePricing, 'LastProcurementPrice'))
    ind = find(dc.s.stockTransactionType == 25 & dc.s.jPurchaseOrder>0 & dc.s.itemNumber == dc.itemNumbers(i));
    if (~isempty(ind))
      lastProcurementFlg(i) = true;
      j = dc.s.jPurchaseOrder(ind);
      purchaseAmount = dc.p.lineAmountOrderCurrency(j);
      datesBuy = dc.s.entryDate(ind);
      datesPay = dc.p.dueDate(j);
      purchaceQuantity = dc.p.invoicedQuantityAlternateUM(j);
      iCurPurchase = dc.p.iCur(j);
      
      if (length(unique(iCurPurchase))>1)
        iCurXi = find(ismember(dm.cName, curFunctional)); % Multiple procurement currencies => use functional currency
      else
        iCurXi = iCurPurchase(1); % Only one procurement currency - Use this for pricing
      end
        
      % Random variable
      rvLastProcurement = clsXiLastProcurement(datesBuy, datesPay, purchaseAmount, purchaceQuantity, iCurPurchase, iCurXi);
    else
      lastProcurementFlg(i) = false;
      ind = find(dc.b.componentNumber == dc.itemNumbers(i));
      if (isempty(ind))
        error('Could not find price for item in BOM structure');
      end
      iCurXi = find(ismember(dm.cName, curFunctional));
      rvLastProcurement = clsXiInternalPrice(dc.b.actualFinishDate(ind), dc.b.costPrice(ind));
    end
  end
  
  if (strcmp(procurementPricing, 'InternalPrice'))
    dc.procurementPrices{i} = rvInternalPrice;
  elseif (strcmp(procurementPricing, 'LastProcurementPrice'))
    dc.procurementPrices{i} = rvLastProcurement;
  end
  if (strcmp(assetPricing, 'InternalPrice'))
    rv = rvInternalPrice;
  elseif (strcmp(assetPricing, 'LastProcurementPrice'))
    rv = rvLastProcurement;
  end
  if (strcmp(salePricing, 'InternalPrice'))
    dc.salePrices{i} = rvInternalPrice;
  elseif (strcmp(salePricing, 'LastProcurementPrice'))
    dc.salePrices{i} = rvLastProcurement;
  end
  iXip = dc.randomVariables.add(rv);
  
  iCurPrice = iCurXi;
  ps = clsPriceStochastic(iCurXi, iCurPrice, iXip);
  dc.assets.add(ps, AssetType.itemInventory);
  
end

fprintf('Correct internal pricing for %d of %d items\n', sum(internalPriceFlg), length(dc.itemNumbers));
fprintf('Correct procurement pricing for %d of %d items\n', sum(lastProcurementFlg), length(dc.itemNumbers));


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Add shrinkage pricing

for i=1:length(dc.itemNumbers)
  iCurPrice = dc.assets.assets{dc.assets.indPriceInventory(1)}.priceCurrency();
  dc.assets.add(clsPriceZero(iCurPrice), AssetType.itemShrinkage);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Add BOM structure

if (~exist('productOrderDate', 'var')) 
  productOrderDate = zeros(size(dc.productNumbers));

  for i=1:length(dc.productNumbers)
    ind = find(dc.b.product == dc.productNumbers(i));
    productOrderDate(i) = min(dc.b.reportingDate(ind));
  end

end

dc.productOrderDate = productOrderDate;

fprintf('Done: BOM\n');
for i=1:length(dc.productNumbers)
  iCurPrice = find(ismember(dm.cName, curFunctional));
  %   dc.assets.add(clsPriceZero(iCurPrice), AssetType.itemManufactured);
  if (strcmp(settings.bomPricing,'DeterministicCashFlows'))
    bom = dc.b(dc.b.product == dc.productNumbers(i), :);
    firstDateBOM = dc.productOrderDate(i); 
    KDates = bom.actualFinishDate;
    K = -bom.CostPriceValue;
    iCurK = ones(size(K))*iCurPrice; % Assumes that all are priced in SEK

    % Add cash flow from final sale
    ii = find(dc.sa.itemNumber == dc.productNumbers(i));
    invoiceNumber = dc.sa.invoiceNumber(ii);
    jj = find(dc.a.transactionCode == 10 & dc.a.invoiceNumber == invoiceNumber);
    kk = find(dc.a.transactionCode == 20 & dc.a.invoiceNumber == invoiceNumber);
    sellingPrice = dc.a.foreignCurrencyAmount(jj);
%     KDates = [KDates ; dc.a.accountingDate(kk)]; % This creates a cash flow in price currency when sold
    KDates = [KDates ; dc.a.accountingDate(jj)]; % Better to syncronize with bond payment - but introduce small error due to difference in time value of money
    K = [K ; sellingPrice];
    iCurK = [iCurK ; dc.a.iCur(jj)]; % Assumes that all are priced in SEK
    
    pb = clsPriceBOM(iCurPrice, firstDateBOM, KDates, K, iCurK);
    dc.assets.add(pb, AssetType.itemManufactured);
  elseif (strcmp(settings.bomPricing, 'StochasticPrices'))
    bom = dc.b(dc.b.product == dc.productNumbers(i), :);
    firstDateBOM = dc.productOrderDate(i); 
    KDates = bom.actualFinishDate;
    nItems = -bom.quantity;
    iXip = ones(size(bom.componentNumber));
    iCurXi = ones(size(bom.componentNumber));
    for j=1:length(iCurXi)
      k = find(bom.componentNumber(j) == dc.itemNumbers);
      kk = dc.assets.indPriceInventory(k);
      iXip(j) = dc.assets.assets{kk}.iXip;
      iCurXi(j) = dc.assets.assets{kk}.iCurXi;
    end
    pb = clsPriceBomXi(iCurPrice, firstDateBOM, KDates, nItems, iXip, iCurXi);
    dc.assets.add(pb, AssetType.itemManufactured);
  end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Add Zero coupon bond pricing for procurement

indPaRange = ((dc.s.entryDate>firstDate) & (dc.s.entryDate<=lastDate)); % Do not use values at t=0
dc.p.jBond = zeros(size(dc.p,1),1); % Index to bond in assets

for k=1:length(dc.itemNumbers)
  ind = find(dc.s.stockTransactionType == 25 & indPaRange & dc.s.itemNumber == dc.itemNumbers(k) & dc.s.jPurchaseOrder ~= 0);
  for i=1:length(ind)
    j = dc.s.jPurchaseOrder(ind(i));
    pb = clsPriceBond(dc.p.iCur(j), dc.s.entryDate(ind(i)), dc.p.dueDate(j), 1, dc.p.iCur(j));
    id = dc.assets.add(pb, AssetType.zeroCouponBond);
    dc.p.jBond(j) = id;
  end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Add Zero coupon bond pricing for sales

indPaRange = ((dc.a.accountingDate>firstDate) & (dc.a.accountingDate<=lastDate)); % Do not use values at t=0
dc.a.jBond = zeros(size(dc.a,1),1); % Index to bond in assets

for i=1:length(dc.productNumbers)
  ii = find(dc.sa.itemNumber == dc.productNumbers(i));
  if (length(ii) ~= 1)
    fprintf('Could not find a unique invoice for product %d\n', dc.productNumbers(i)); error('Exiting');
  end
  invoiceNumber = dc.sa.invoiceNumber(ii);
  jj = find(dc.a.transactionCode == 10 & indPaRange & dc.a.invoiceNumber == invoiceNumber);
  kk = find(dc.a.transactionCode == 20 & dc.a.invoiceNumber == invoiceNumber);
  if (length(jj) ~= 1 || length(kk) ~= 1)
    fprintf('Could not find accounts receiveable for invoice %d\n', invoiceNumber); error('Exiting');
  end

  pb = clsPriceBond(dc.a.iCur(jj), dc.a.accountingDate(jj), dc.a.accountingDate(kk), 1, dc.a.iCur(jj));
  id = dc.assets.add(pb, AssetType.zeroCouponBond);
  dc.a.jBond(jj) = id;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Add Zero coupon bond pricing for accounts payable
% Per thesis: AP ZCB spans from procurement order date (t^proc) to supplier
% payment date (t^pay). The AP position is SHORT (negative holding = liability).

indPaRangeAP = ((dc.ap.accountingDate>firstDate) & (dc.ap.accountingDate<=lastDate));
dc.ap.jBond = zeros(size(dc.ap,1),1);

apOrderNums = unique(dc.ap.invoiceNumber);
for i=1:length(apOrderNums)
  jj = find(dc.ap.transactionCode == 10 & indPaRangeAP & dc.ap.invoiceNumber == apOrderNums(i));
  kk = find(dc.ap.transactionCode == 20 & dc.ap.invoiceNumber == apOrderNums(i));
  if (isempty(jj) || isempty(kk))
    fprintf('Could not find accounts payable pair for PO %d\n', apOrderNums(i)); continue;
  end
  pb = clsPriceBond(dc.ap.iCur(jj), dc.ap.accountingDate(jj), dc.ap.accountingDate(kk), 1, dc.ap.iCur(jj));
  id = dc.assets.add(pb, AssetType.zeroCouponBond);
  dc.ap.jBond(jj) = id;
end

% Create indices from xif, xiI and xiP to xi-vector

dc.xif2xiInd = dm.curMat2vec;
dc.xiI2xiInd = cell(nc,1);
nPCtot = 0;
for i=1:nc
  nPC = size(dm.E{i}, 2);
  dc.xiI2xiInd{i} = (nc*nc+nPCtot) + (1:nPC)';
  nPCtot = nPCtot + nPC;
end
dc.xiP2xiInd = (nc*nc+nPCtot) + (1:length(dc.randomVariables.randomVariables))';

dc.xiP = dc.randomVariables.states(dm);

dc.xi = [dm.xif dm.xiI dc.xiP];

% Create name strings for each risk factor

dc.xiName = cell(size(dc.xi,2),1);

for ki=1:nc
  for kj=1:nc
    dc.xiName{dm.curMat2vec(ki,kj)} = [dm.cName{kj} '/' dm.cName{ki}];
  end
end

for i=1:nc
  nPC = size(dm.E{i}, 2);
  for j=1:nPC
    dc.xiName{dc.xiI2xiInd{i}(j)} = [dm.cName{i} 'PC' num2str(j)];
  end
end

for i=1:length(dc.itemNumbers)
  % dc.xiName{dc.xiP2xiInd(i)} = ['item' num2str(dc.itemNumbers(i))];
  dc.xiName{dc.xiP2xiInd(i)} = ['item' dc.itemNumberDictionary{dc.itemNumbers(i)}];
end


% for i=1:length(dc.assets.assets)
%   fprintf('Asset %d\n', i);
%   checkDerivative(dm, dc, dc.assets.assets{i});
% end


% % Get determinitic PriceS, Gradient and Hessian
% for k=1:length(dc.itemNumbers)
%   ind = find(dc.s.stockTransactionType == 25 & indPaRange & dc.s.itemNumber == dc.itemNumbers(k));
%   p = cell(length(ind),1);
%   g = cell(length(ind),1);
%   H = cell(length(ind),1);
%   for i=1:length(ind)
%     j = dc.s.jPurchaseOrder(ind(i));
%     pb = clsPriceBond(dc.p.iCur(j), dc.s.entryDate(ind(i)), dc.p.dueDate(j), 1, dc.p.iCur(j));
%     id = dc.assets.add(pb, AssetType.zeroCouponBond);
%     dc.p.jBond(j) = id;
%     %checkDerivative(dm, dp, pb);
%     [p{i}, g{i}, H{i}] = pb.price(dm, dc);
%     dc.det_price = p;
%     dc.det_grad = g;
%     dc.det_hess = H;
%   end
% end
% 
% % Get stochastic PriceS, Gradient and Hessian
% 
% 
% obj = clsPriceStochastic(iCurXi, iCurPrice, iXip);
% [p_sto, g_sto, H_sto] = obj.price(dm, dc);
% dc.sto_price = p_sto;
% dc.sto_grad = g_sto;
% dc.sto_hess = H_sto;



