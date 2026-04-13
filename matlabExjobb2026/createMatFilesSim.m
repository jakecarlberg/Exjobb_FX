rng(1);

% =========================================================================
% CURRENCY SETUP
% Functional currency: EUR  |  Presentation currency: SEK
% =========================================================================
curFunctional    = 'EUR';
curPresentation  = 'SEK';
iCurFunctional   = find(ismember(dm.cName, curFunctional));
iCurPresentation = find(ismember(dm.cName, curPresentation));

% =========================================================================
% DATE RANGE (business days only)
% =========================================================================
startDate = datenum(2005,1,1);   % Thesis Section 4.2.1: January 2005
endDate   = datenum(2025,12,31); % Thesis Section 4.2.1: December 2025

dates = startDate:endDate;
wd    = weekday(dates);
dates(wd==1 | wd==7) = [];   % Remove Sat(7) and Sun(1)
nDates = length(dates);

% Helper: map a calendar date d to the nearest dm index
getdmInd = @(d) dm.indAllDates(max(1, min(round(d) - dm.dates(1) + 1, length(dm.indAllDates))));

% =========================================================================
% COMPONENT DEFINITIONS  (10 components, each with a FIXED procurement currency)
%
%   #   Name             Prmt.cur   Base price (in procurement currency)
%   1   CarbidePowder    USD        100
%   2   CoatingAgent     EUR         20
%   3   SteelBody        EUR         50
%   4   CarbideInsert    USD        400
%   5   FastenersB       CNY          5
%   6   SteelFrame       EUR      2 000
%   7   HydraulicUnit    USD      5 000
%   8   Electronics      GBP      8 000
%   9   CarbideWear      USD        500
%  10   FastenersC       CNY         10
% =========================================================================
nComponents  = 10;
compCurStr   = {'USD','EUR','EUR','USD','CNY','EUR','USD','GBP','USD','CNY'};
compPriceInit = [100, 20, 50, 400, 5, 2000, 5000, 8000, 500, 10];

compIcur = zeros(1, nComponents);
for j = 1:nComponents
  compIcur(j) = find(ismember(dm.cName, compCurStr{j}));
end

% =========================================================================
% BOM PRODUCT TYPES  (3 types, 5 products each = 15 total)
%
%   Type A (products  1- 5):  components 1,2         (consumable tool)
%   Type B (products  6-10):  components 3,4,5        (assembled tool)
%   Type C (products 11-15):  components 6,7,8,9,10   (equipment)
% =========================================================================
typeComponents = {[1,2], [3,4,5], [6,7,8,9,10]};
typeQuantities  = {[5,2], [1,3,10], [1,2,5,4,20]};

nBOM     = 15;
nPerType =  5;

% =========================================================================
% SALES CURRENCY ASSIGNMENT  (thesis Table 4.5, foreign-only exposure)
%   USD 38%, AUD 12%, CAD 7%, GBP 6%, ZAR 5%, INR 5%, CNY 5%
% =========================================================================
saleCurNames = {'USD','AUD','CAD','GBP','ZAR','INR','CNY'};
saleWeights  = [0.38, 0.12, 0.07, 0.06, 0.05, 0.05, 0.05];
saleWeights  = saleWeights / sum(saleWeights);   % normalise to 1

saleCurIcur = zeros(1, length(saleCurNames));
for j = 1:length(saleCurNames)
  saleCurIcur(j) = find(ismember(dm.cName, saleCurNames{j}));
end

% Assign a sales currency to each of the 15 BOM orders
iSaleCurBOM = randsample(length(saleCurNames), nBOM, true, saleWeights);

% =========================================================================
% GBM COMPONENT PRICES  (in procurement currency)
% =========================================================================
dt     = (endDate - startDate) / (365 * nDates);
cMu    = ones(nComponents, 1) * 0.02 * dt;
cSigma = ones(nComponents, 1) * 0.05 * sqrt(dt);

cPrices = repmat(compPriceInit, nDates, 1) .* exp(cumsum( ...
  repmat(cMu', nDates, 1) + randn(nDates, nComponents) .* repmat(cSigma', nDates, 1)));

% Quarterly costing prices (step function, updated at Jan/Apr/Jul/Oct)
cPricesQ       = cPrices;
cCostingData   = [(1:nComponents)' ones(nComponents,1)*startDate compPriceInit'];

for i = 2:nDates
  mo = month(dates(i));
  if (month(dates(i-1)) ~= mo && (mo==1 || mo==4 || mo==7 || mo==10))
    cCostingData = [cCostingData; (1:nComponents)' ones(nComponents,1)*dates(i) cPrices(i,:)']; %#ok<AGROW>
  else
    cPricesQ(i,:) = cPricesQ(i-1,:);
  end
end

c = table(ones(size(cCostingData,1),1), cCostingData(:,1), cCostingData(:,2), cCostingData(:,3), ...
  'VariableNames', {'facility','itemNumber','costingDate','CostingSum1'});
save('simulatedData\costing', 'c');

% =========================================================================
% TIMING PARAMETERS  (thesis Table 4.7)
% =========================================================================
procLeadMean = 45;  procLeadStd = 10;   % days: component procurement lead
mfgMean      = 20;  mfgStd      =  5;   % days: manufacturing duration
custPayMean  = 45;  custPayStd  = 15;   % days: customer payment delay after invoice
suppPayMean  = 60;  suppPayStd  = 15;   % days: supplier payment delay after receipt
grossMargin  = 0.40;                    % gross margin target (~40 %)

% Manufacturing start-date window (enough buffer for procurement at start
% and customer payment at end)
bufferStart = procLeadMean + 3*procLeadStd + mfgMean + 3*mfgStd + 10;
bufferEnd   = custPayMean  + 3*custPayStd  + 10;

iStart = find(dates >= startDate + bufferStart, 1);
iEnd   = find(dates <= endDate   - bufferEnd,   1, 'last');

% Evenly-spaced manufacturing start dates with small jitter
bomStartInds = round(linspace(iStart, iEnd, nBOM));
bomStartInds = sort(max(iStart, min(iEnd, bomStartInds + round(randn(1,nBOM)*5))));

% =========================================================================
% PRE-ALLOCATE COLUMN VECTORS FOR OUTPUT TABLES
% =========================================================================

% BOM
b_product      = zeros(0,1);   b_compNum     = zeros(0,1);
b_qty          = zeros(0,1);   b_refOrder    = zeros(0,1);
b_repDate      = zeros(0,1);   b_costPrice   = zeros(0,1);
b_finishDate   = zeros(0,1);   b_costPriceVal= zeros(0,1);

% Purchase orders
p_poNum   = zeros(0,1);  p_itemNum = zeros(0,1);
p_txCode  = zeros(0,1);  p_cur     = {};
p_poNum1  = zeros(0,1);  p_qty     = zeros(0,1);
p_accDate = zeros(0,1);  p_dueDate = zeros(0,1);
p_amount  = zeros(0,1);

% Stock transactions – procurement (type 25)
sp_itemNum = zeros(0,1);  sp_txType = zeros(0,1);
sp_ohBal   = zeros(0,1);  sp_qty    = zeros(0,1);
sp_entDate = zeros(0,1);  sp_ordNum = zeros(0,1);
sp_implOH  = zeros(0,1);

% Stock transactions – consumption (type 11)
sc_itemNum = zeros(0,1);  sc_txType = zeros(0,1);
sc_ohBal   = zeros(0,1);  sc_qty    = zeros(0,1);
sc_entDate = zeros(0,1);  sc_ordNum = zeros(0,1);
sc_implOH  = zeros(0,1);

% Sales
sa_invoiceNum = (1:nBOM)';   sa_itemNum  = (1:nBOM)';
sa_fxAmt      = zeros(nBOM,1); sa_localAmt = zeros(nBOM,1);
sa_costPrice  = zeros(nBOM,1); sa_cur      = cell(nBOM,1);

% Accounts receivable (2 rows per BOM: invoice + payment)
a_invoiceNum = zeros(2*nBOM,1);  a_txCode  = zeros(2*nBOM,1);
a_fxAmt      = zeros(2*nBOM,1);  a_cur     = cell(2*nBOM,1);
a_dueDate    = zeros(2*nBOM,1);  a_accDate = zeros(2*nBOM,1);

productOrderDate = zeros(nBOM,1);
pi = 1;   % running purchase-order index

% =========================================================================
% MAIN LOOP: GENERATE ALL BOM ORDERS
% =========================================================================
for i = 1:nBOM

  % ---- Product type ----
  if     i <= nPerType,    typeIdx = 1;
  elseif i <= 2*nPerType,  typeIdx = 2;
  else,                    typeIdx = 3;
  end
  compIdx = typeComponents{typeIdx};
  compQty = typeQuantities{typeIdx};
  nComp   = length(compIdx);

  % ---- Manufacturing timing ----
  mfgDays   = max(1, round(mfgMean + mfgStd*randn()));
  iMfgStart = bomStartInds(i);
  iMfgEnd   = min(nDates, iMfgStart + mfgDays);
  mfgStart  = dates(iMfgStart);
  mfgFinish = dates(iMfgEnd);
  productOrderDate(i) = mfgStart;

  iDmMfgStart = getdmInd(mfgStart);
  iDmMfgEnd   = getdmInd(mfgFinish);

  % ---- COGS in EUR (functional currency) ----
  cogsEUR = 0;
  for j = 1:nComp
    cj = compIdx(j);
    priceProcCur = cPricesQ(iMfgStart, cj);              % price/unit in procurement cur
    fxProcToEUR  = dm.fx{compIcur(cj), iCurFunctional}(iDmMfgStart);  % EUR per procCur unit
    cogsEUR      = cogsEUR + priceProcCur * compQty(j) * fxProcToEUR;
  end

  % ---- Revenue in EUR and sales currency ----
  revenueEUR  = cogsEUR / (1 - grossMargin);

  iSaleType   = iSaleCurBOM(i);
  curSaleStr  = saleCurNames{iSaleType};
  iCurSale    = saleCurIcur(iSaleType);
  fxEURtoSale = dm.fx{iCurFunctional, iCurSale}(iDmMfgEnd);   % saleCur per EUR
  revenueSale = revenueEUR * fxEURtoSale;

  % ---- Customer payment timing ----
  custPay     = max(7, round(custPayMean + custPayStd*randn()));
  invoiceDate = mfgFinish + 7;          % invoice sent ~1 week after finish
  arDueDate   = invoiceDate + custPay;
  arWd = weekday(arDueDate);
  if (arWd == 7), arDueDate = arDueDate - 1; end   % Sat -> Fri
  if (arWd == 1), arDueDate = arDueDate - 2; end   % Sun -> Fri

  % ---- Fill sales table ----
  sa_fxAmt(i)    = revenueSale;
  sa_localAmt(i) = revenueEUR;
  sa_costPrice(i)= cogsEUR;
  sa_cur{i}      = curSaleStr;

  % ---- Fill AR table (row pair: invoice + payment) ----
  r1 = 2*(i-1)+1;   r2 = 2*(i-1)+2;

  a_invoiceNum(r1) = i;   a_txCode(r1)  = 10;           % invoice
  a_fxAmt(r1)      = revenueSale;
  a_cur{r1}        = curSaleStr;
  a_accDate(r1)    = invoiceDate;
  a_dueDate(r1)    = arDueDate;

  a_invoiceNum(r2) = i;   a_txCode(r2)  = 20;           % payment received
  a_fxAmt(r2)      = -revenueSale;
  a_cur{r2}        = curSaleStr;
  a_dueDate(r2)    = arDueDate;
  a_accDate(r2)    = arDueDate;

  % ---- Components: BOM rows + procurement + stock transactions ----
  for j = 1:nComp
    cj     = compIdx(j);
    qBuy   = compQty(j);
    curStr = compCurStr{cj};

    % Procurement timing
    procLead  = max(5, round(procLeadMean + procLeadStd*randn()));
    iProcDate = max(1, iMfgStart - procLead);
    procDate  = dates(iProcDate);

    % Supplier payment
    suppPay = max(1, round(suppPayMean + suppPayStd*randn()));
    apDue   = procDate + suppPay;
    apWd = weekday(apDue);
    if (apWd == 7), apDue = apDue - 1; end
    if (apWd == 1), apDue = apDue - 2; end

    % Prices
    costPriceAtOrder = cPricesQ(iMfgStart, cj);     % quarterly cost at mfg start (for BOM.costPrice)
    procCurPrice     = cPricesQ(iProcDate,  cj);     % price actually paid at procurement date
    totalAmtProcCur  = procCurPrice * qBuy;           % total order amount in procurement currency

    % BOM row
    b_product      = [b_product;       i];
    b_compNum      = [b_compNum;       cj];
    b_qty          = [b_qty;           qBuy];
    b_refOrder     = [b_refOrder;      0];
    b_repDate      = [b_repDate;       mfgStart];    % component consumed when mfg begins
    b_costPrice    = [b_costPrice;     costPriceAtOrder];
    b_finishDate   = [b_finishDate;    mfgFinish];
    b_costPriceVal = [b_costPriceVal;  qBuy * costPriceAtOrder];

    % Purchase order
    p_poNum(end+1,1)  = pi;
    p_itemNum(end+1,1)= cj;
    p_txCode(end+1,1) = 40;
    p_cur{end+1,1}    = curStr;
    p_poNum1(end+1,1) = pi;
    p_qty(end+1,1)    = qBuy;
    p_accDate(end+1,1)= procDate;     % accountingDate = receipt date
    p_dueDate(end+1,1)= apDue;
    p_amount(end+1,1) = totalAmtProcCur;

    % Stock transaction: procurement receipt (type 25)
    sp_itemNum(end+1,1) = cj;
    sp_txType(end+1,1)  = 25;
    sp_ohBal(end+1,1)   = 0;
    sp_qty(end+1,1)     = qBuy;
    sp_entDate(end+1,1) = procDate;   % entryDate must equal p.accountingDate
    sp_ordNum(end+1,1)  = pi;         % orderNumber = purchaseOrderNumber
    sp_implOH(end+1,1)  = 0;

    % Stock transaction: manufacturing consumption (type 11)
    sc_itemNum(end+1,1) = cj;
    sc_txType(end+1,1)  = 11;
    sc_ohBal(end+1,1)   = 0;
    sc_qty(end+1,1)     = -qBuy;
    sc_entDate(end+1,1) = mfgStart;   % consumed at start of manufacturing
    sc_ordNum(end+1,1)  = i;          % orderNumber = product (BOM product)
    sc_implOH(end+1,1)  = 0;

    pi = pi + 1;
  end
end

% =========================================================================
% BUILD TABLES
% =========================================================================

b = table(b_product, b_compNum, b_qty, b_refOrder, b_repDate, b_costPrice, b_finishDate, b_costPriceVal, ...
  'VariableNames', {'product','componentNumber','quantity','referenceOrderNumber', ...
                    'reportingDate','costPrice','actualFinishDate','CostPriceValue'});

p = table(p_poNum, p_itemNum, p_txCode, p_cur, p_poNum1, p_qty, p_accDate, p_dueDate, p_amount, ...
  'VariableNames', {'purchaseOrderNumber','itemNumber','transactionCode','currency', ...
                    'purchaseOrderNumber_1','invoicedQuantityAlternateUM','accountingDate','dueDate','lineAmountOrderCurrency'});

sa = table(sa_invoiceNum, sa_itemNum, sa_fxAmt, sa_localAmt, sa_costPrice, sa_cur, ...
  'VariableNames', {'invoiceNumber','itemNumber','foreignCurrencyAmount','lineAmountLocalCurrency','costPrice','currency'});

a = table(a_invoiceNum, a_txCode, a_fxAmt, a_cur, a_dueDate, a_accDate, ...
  'VariableNames', {'invoiceNumber','transactionCode','foreignCurrencyAmount','currency','dueDate','accountingDate'});

% =========================================================================
% STOCK TRANSACTIONS: combine, sort by date, compute on-hand balance
% =========================================================================
sNames = {'itemNumber','stockTransactionType','newOnHandBalance', ...
          'transactionQuantityBasicUM','entryDate','orderNumber','impliedOnHandBalance'};

sp_table = table(sp_itemNum, sp_txType, sp_ohBal, sp_qty, sp_entDate, sp_ordNum, sp_implOH, 'VariableNames', sNames);
sc_table = table(sc_itemNum, sc_txType, sc_ohBal, sc_qty, sc_entDate, sc_ordNum, sc_implOH, 'VariableNames', sNames);

s = [sp_table; sc_table];
[~, sortInd] = sort(s.entryDate);
s = s(sortInd, :);

% On-hand balance per component
for j = 1:nComponents
  ind = find(s.itemNumber == j);
  if ~isempty(ind)
    stock = cumsum(s.transactionQuantityBasicUM(ind));
    s.newOnHandBalance(ind)    = stock;
    s.impliedOnHandBalance(ind)= stock;
  end
end

% Fix any weekend due-dates in purchase orders (move to prior Friday)
wd = weekday(p.dueDate);
p.dueDate(wd==7) = p.dueDate(wd==7) - 1;   % Sat -> Fri
p.dueDate(wd==1) = p.dueDate(wd==1) - 2;   % Sun -> Fri

% =========================================================================
% ITEM / PRODUCT DICTIONARIES
% =========================================================================
itemNumberDictionary    = cellstr(num2str((1:nComponents)', '%010.0f'));
productNumberDictionary = cellstr(num2str((1:nBOM)',        '%010.0f'));

% =========================================================================
% SAVE ALL FILES
% =========================================================================
save('simulatedData\costing',              'c');
save('simulatedData\BOM',                  'b', 'productOrderDate');
save('simulatedData\Sales',                'sa');
save('simulatedData\AccountsReceivable',   'a');
save('simulatedData\stockTransactions',    's');
save('simulatedData\purchaseOrder',        'p');
save('simulatedData\itemNumberDictionary', 'itemNumberDictionary', 'productNumberDictionary');

% =========================================================================
% SUMMARY
% =========================================================================
fprintf('\n=== Multi-Currency Simulation Created ===\n');
fprintf('Date range    : %s  to  %s\n', datestr(startDate), datestr(endDate));
fprintf('Components    : %d  |  procurement currencies: %s\n', nComponents, strjoin(unique(compCurStr), ', '));
fprintf('BOM products  : %d  (3 types, %d each)\n', nBOM, nPerType);
fprintf('Purchase orders: %d\n', size(p,1));
fprintf('Procurement currencies used: %s\n', strjoin(unique(p.currency)', ', '));
fprintf('Sales currencies used      : %s\n', strjoin(unique(sa.currency)', ', '));
fprintf('Functional currency (EUR)  : %s (index %d)\n', curFunctional, iCurFunctional);
fprintf('Presentation currency (SEK): %s (index %d)\n', curPresentation, iCurPresentation);
