function createMatFilesSim(dm, seed, verbose)
% createMatFilesSim  Generate synthetic multi-currency transaction data.
%
%   createMatFilesSim(dm, seed, verbose)
%
%   dm      - market data struct from createDataMarket (provides FX rates)
%   seed    - RNG seed for reproducibility (default 1)
%   verbose - print year-by-year summary to console (default true)
%
% The function generates a 21-year transaction history (2005-2025) for a
% simulated manufacturing subsidiary.  Revenue and gross margin are
% calibrated year by year to Sandvik's reported figures (Tables 4.3-4.4).
% Component prices are scaled annually so that total COGS matches the
% target margin.  The function writes all .mat files to simulatedData/ and
% is designed to be called repeatedly inside a Monte Carlo loop (runMC.m).

if nargin < 2 || isempty(seed),    seed    = 1;    end
if nargin < 3 || isempty(verbose), verbose = true; end

rng(seed);

%% ========================================================================
%  CONFIGURABLE ASSUMPTIONS  -  edit these arrays to change the simulation
%% ========================================================================

% --- Currency setup ------------------------------------------------------
curFunctional   = 'EUR';
curPresentation = 'SEK';
iCurFunctional  = find(ismember(dm.cName, curFunctional));

% --- Simulation start year ------------------------------------------------
% Change this to 2005 once FX/yield data is available back to Jan 2005.
% All arrays below cover 2005-2025 (21 elements); the simulation slices
% from simStartYear onward.
simStartYear = 2007;  % <-- CHANGE TO 2005 WHEN DATA IS AVAILABLE

% --- Revenue: start value and annual growth rates (Tables 4.3-4.4) -------
%            2005  2006  2007  2008  2009  2010  2011  2012  2013  2014
%            2015  2016  2017  2018  2019  2020  2021  2022  2023  2024  2025
startRevenue    = 500e6;   % EUR, year 2005 (base year for compounding)
revenueGrowthPct = [NaN, 18.2, 17.5,  4.2, -25.1, 10.8, 22.1, -3.5, -1.2,  0.8, ...
                   -8.6, -6.1, 12.0, 16.5,  -0.8,-13.2, 17.0, 31.1, 12.6, -2.9, -1.8];

% --- Gross margin per year (%) (Tables 4.3-4.4) -------------------------
grossMarginPct = [42.5, 43.1, 43.0, 41.8, 36.2, 39.5, 41.0, 40.1, 39.8, 39.5, ...
                  41.0, 40.8, 40.2, 41.5, 41.2, 40.8, 42.8, 40.4, 41.1, 40.0, 40.6];

% --- Inflation per year (%) - placeholder, update with actual data -------
inflationPct = 2.0 * ones(1, 21);  % 2% flat placeholder

% --- Base selling prices per product type (EUR, year 2005) ---------------
baseSellPriceEUR = [1000000, 5000000, 20000000];  % Type A, B, C (batch/lot level)

% --- Product mix probabilities (by unit count) ---------------------------
productMixWeights = [0.60, 0.25, 0.15];  % Type A, B, C

% --- Sales currency exposure (Table 4.5) ---------------------------------
saleCurNames   = {'USD','EUR','AUD','CAD','GBP','ZAR','INR','CNY'};
saleExposurePct = [38,   22,   12,    7,    6,    5,    5,    5  ];

% --- Cash management -----------------------------------------------------
cashRetentionFrac = 0.10;  % retain 10% of prior year COGS; sweep rest to parent

% --- Timing parameters (Table 4.7) — unchanged --------------------------
procLeadMean = 45;  procLeadStd = 10;   % days: procurement lead time
mfgMean      = 20;  mfgStd      =  5;   % days: manufacturing duration
custPayMean  = 45;  custPayStd  = 15;   % days: customer payment delay
suppPayMean  = 60;  suppPayStd  = 15;   % days: supplier payment delay

%% ========================================================================
%  COMPONENT & BOM DEFINITIONS  (fixed structure)
%% ========================================================================

nComponents   = 10;
compCurStr    = {'USD','EUR','EUR','USD','CNY','EUR','USD','GBP','USD','CNY'};
compPriceInit = [100, 20, 50, 400, 5, 2000, 5000, 8000, 500, 10];

compIcur = zeros(1, nComponents);
for j = 1:nComponents
  compIcur(j) = find(ismember(dm.cName, compCurStr{j}));
end

% BOM product types
typeComponents = {[1,2], [3,4,5], [6,7,8,9,10]};
typeQuantities = {[5,2], [1,3,10], [1,2,5,4,20]};
nTypes = length(typeComponents);

%% ========================================================================
%  COMPUTE YEAR-BY-YEAR TARGETS
%% ========================================================================

allYears = 2005:2025;  % full range for arrays

% Compute revenue for ALL years first (compounding from 2005 base)
allRevenue = zeros(1, length(allYears));
allRevenue(1) = startRevenue;
for y = 2:length(allYears)
  allRevenue(y) = allRevenue(y-1) * (1 + revenueGrowthPct(y)/100);
end

% Slice to simulation window
iStart   = find(allYears == simStartYear);
simYears = allYears(iStart:end);
nYears   = length(simYears);

% Slice all calibration arrays to match
revenueGrowthPct = revenueGrowthPct(iStart:end);
grossMarginPct   = grossMarginPct(iStart:end);
inflationPct     = inflationPct(iStart:end);

% Revenue targets (compounded from 2005 base, sliced to sim window)
targetRevenue = allRevenue(iStart:end);

% COGS targets
targetCOGS = targetRevenue .* (1 - grossMarginPct/100);

% Selling prices per type per year (inflation-adjusted from 2005 base)
allInflation = 2.0 * ones(1, length(allYears));  % full 2005-2025 inflation
allInflation(iStart:end) = inflationPct;          % overwrite with sliced values
allSellPrice = zeros(nTypes, length(allYears));
for t = 1:nTypes
  allSellPrice(t, 1) = baseSellPriceEUR(t);
  for y = 2:length(allYears)
    allSellPrice(t, y) = allSellPrice(t, y-1) * (1 + allInflation(y)/100);
  end
end
sellPriceByYear = allSellPrice(:, iStart:end);

% Sales currency indices
saleCurIcur = zeros(1, length(saleCurNames));
for j = 1:length(saleCurNames)
  saleCurIcur(j) = find(ismember(dm.cName, saleCurNames{j}));
end

%% ========================================================================
%  DATE RANGE (business days only, aligned with market data)
%% ========================================================================

startDate = dm.dates(1);
endDate   = dm.dates(end);

allDates = startDate:endDate;
wd       = weekday(allDates);
allDates(wd==1 | wd==7) = [];   % Remove Sat/Sun
nDates = length(allDates);

% Helper: map a calendar date to the nearest dm index
getdmInd = @(d) dm.indAllDates(max(1, min(round(d) - dm.dates(1) + 1, length(dm.indAllDates))));

% Year boundaries in the allDates vector
yearStartIdx = zeros(nYears, 1);
yearEndIdx   = zeros(nYears, 1);
for y = 1:nYears
  yy = simYears(y);
  inds = find(year(datetime(allDates, 'ConvertFrom', 'datenum')) == yy);
  if isempty(inds)
    % Fallback for years outside market data range
    yearStartIdx(y) = 1;
    yearEndIdx(y)   = 1;
  else
    yearStartIdx(y) = inds(1);
    yearEndIdx(y)   = inds(end);
  end
end

%% ========================================================================
%  DETERMINE NUMBER OF ORDERS PER YEAR
%% ========================================================================

% Weighted average selling price per year (using product mix weights)
avgSellPrice = zeros(1, nYears);
for y = 1:nYears
  avgSellPrice(y) = sum(productMixWeights .* sellPriceByYear(:, y)');
end

% Number of orders per year
nOrdersPerYear = zeros(1, nYears);
for y = 1:nYears
  nOrdersPerYear(y) = max(1, round(targetRevenue(y) / avgSellPrice(y)));
end

nBOM_total = sum(nOrdersPerYear);

%% ========================================================================
%  COMPUTE ALPHA (cost scaling) PER YEAR
%% ========================================================================

% For each year, compute what COGS would be at alpha=1 (using base component
% prices and beginning-of-year FX rates), then solve alpha = targetCOGS / cogsBase

alphaByYear = zeros(1, nYears);

for y = 1:nYears
  % FX rates at beginning of year
  iDmBOY = getdmInd(allDates(yearStartIdx(y)));

  % Compute COGS per unit at alpha=1 for each product type
  cogsPerUnit = zeros(1, nTypes);
  for t = 1:nTypes
    compIdx = typeComponents{t};
    compQty = typeQuantities{t};
    for j = 1:length(compIdx)
      cj = compIdx(j);
      fxToEUR = dm.fx{compIcur(cj), iCurFunctional}(iDmBOY);
      cogsPerUnit(t) = cogsPerUnit(t) + compPriceInit(cj) * compQty(j) * fxToEUR;
    end
  end

  % Expected number of each type this year
  nPerType = round(productMixWeights * nOrdersPerYear(y));
  nPerType(end) = nOrdersPerYear(y) - sum(nPerType(1:end-1));  % fix rounding

  cogsBase = sum(nPerType .* cogsPerUnit);
  alphaByYear(y) = targetCOGS(y) / cogsBase;
end

%% ========================================================================
%  PRE-ALLOCATE OUTPUT VECTORS
%% ========================================================================

% Upper bound on total POs: each order can have at most max-components
maxCompPerOrder = max(cellfun(@length, typeComponents));
nTotalPO = nBOM_total * maxCompPerOrder;  % safe upper bound; trimmed later

% BOM
b_product    = zeros(nTotalPO, 1);  b_compNum     = zeros(nTotalPO, 1);
b_qty        = zeros(nTotalPO, 1);  b_refOrder    = zeros(nTotalPO, 1);
b_repDate    = zeros(nTotalPO, 1);  b_costPrice   = zeros(nTotalPO, 1);
b_finishDate = zeros(nTotalPO, 1);  b_costPriceVal= zeros(nTotalPO, 1);

% Purchase orders
p_poNum   = zeros(nTotalPO, 1);  p_itemNum = zeros(nTotalPO, 1);
p_txCode  = zeros(nTotalPO, 1);  p_cur     = cell(nTotalPO, 1);
p_poNum1  = zeros(nTotalPO, 1);  p_qty     = zeros(nTotalPO, 1);
p_accDate = zeros(nTotalPO, 1);  p_dueDate = zeros(nTotalPO, 1);
p_amount  = zeros(nTotalPO, 1);

% Stock transactions (procurement + consumption = 2 * nTotalPO)
nStockRows = 2 * nTotalPO;
s_itemNum = zeros(nStockRows, 1);  s_txType = zeros(nStockRows, 1);
s_ohBal   = zeros(nStockRows, 1);  s_qty    = zeros(nStockRows, 1);
s_entDate = zeros(nStockRows, 1);  s_ordNum = zeros(nStockRows, 1);
s_implOH  = zeros(nStockRows, 1);

% Sales
sa_invoiceNum = (1:nBOM_total)';
sa_itemNum    = (1:nBOM_total)';
sa_fxAmt      = zeros(nBOM_total, 1);
sa_localAmt   = zeros(nBOM_total, 1);
sa_costPrice  = zeros(nBOM_total, 1);
sa_cur        = cell(nBOM_total, 1);

% Accounts receivable (2 rows per sale)
a_invoiceNum = zeros(2*nBOM_total, 1);  a_txCode  = zeros(2*nBOM_total, 1);
a_fxAmt      = zeros(2*nBOM_total, 1);  a_cur     = cell(2*nBOM_total, 1);
a_dueDate    = zeros(2*nBOM_total, 1);  a_accDate = zeros(2*nBOM_total, 1);

% Accounts payable (2 rows per PO)
ap_invoiceNum = zeros(2*nTotalPO, 1);  ap_txCode  = zeros(2*nTotalPO, 1);
ap_fxAmt      = zeros(2*nTotalPO, 1);  ap_cur     = cell(2*nTotalPO, 1);
ap_dueDate    = zeros(2*nTotalPO, 1);  ap_accDate = zeros(2*nTotalPO, 1);

% Costing table
cCostingData = [];

productOrderDate = zeros(nBOM_total, 1);

%% ========================================================================
%  MAIN LOOP: YEAR BY YEAR
%% ========================================================================

productId = 0;   % running product counter across years
poId      = 0;   % running purchase order counter
bomRowId  = 0;   % running BOM/PO row counter
stockRowId = 0;  % running stock row counter
cashBalance = 0;

% Summary arrays for verbose output
summActRevenue  = zeros(1, nYears);
summActCOGS     = zeros(1, nYears);
summNOrders     = zeros(1, nYears);
summDividend    = zeros(1, nYears);
summCash        = zeros(1, nYears);
summTypeCounts  = zeros(nYears, nTypes);           % product split per year
summCurRevenue  = zeros(nYears, length(saleCurNames)); % revenue per currency per year

for y = 1:nYears

  alpha = alphaByYear(y);
  nOrdersY = nOrdersPerYear(y);

  % --- Determine product types for this year (random draw) ---------------
  typeAssignment = zeros(nOrdersY, 1);
  cdf = cumsum(productMixWeights);
  for i = 1:nOrdersY
    typeAssignment(i) = find(rand() <= cdf, 1, 'first');
  end

  % --- Assign sales currencies to meet exposure ratios -------------------
  saleWeightsNorm = saleExposurePct / sum(saleExposurePct);
  targetCurCount  = round(saleWeightsNorm * nOrdersY);
  % Fix rounding: adjust largest bucket
  diff = nOrdersY - sum(targetCurCount);
  [~, iMax] = max(targetCurCount);
  targetCurCount(iMax) = targetCurCount(iMax) + diff;

  % Build shuffled currency assignment vector
  curAssignment = zeros(nOrdersY, 1);
  idx = 1;
  for c = 1:length(saleCurNames)
    curAssignment(idx:idx+targetCurCount(c)-1) = c;
    idx = idx + targetCurCount(c);
  end
  curAssignment = curAssignment(randperm(nOrdersY));

  % --- Manufacturing start dates: uniform random within year -------------
  bufferStart = procLeadMean + 3*procLeadStd + mfgMean + 3*mfgStd + 10;
  bufferEnd   = custPayMean  + 3*custPayStd  + 10;

  iYearStart = yearStartIdx(y);
  iYearEnd   = yearEndIdx(y);

  iValidStart = iYearStart + round(bufferStart / 1.4);  % ~business days
  iValidEnd   = iYearEnd   - round(bufferEnd   / 1.4);

  if iValidStart > iValidEnd
    % Narrow year — use full year range (some payments may spill over)
    iValidStart = iYearStart;
    iValidEnd   = iYearEnd;
  end

  bomStartInds = sort(randi([iValidStart, iValidEnd], 1, nOrdersY));

  % --- Costing table entries for this year (quarterly) -------------------
  for q = [1, 4, 7, 10]
    qDate = datenum(simYears(y), q, 1);
    % Find nearest business day
    qIdx = find(allDates >= qDate, 1, 'first');
    if ~isempty(qIdx) && qIdx >= iYearStart && qIdx <= iYearEnd
      for cj = 1:nComponents
        cCostingData = [cCostingData; 1, cj, allDates(qIdx), alpha * compPriceInit(cj)]; %#ok<AGROW>
      end
    end
  end

  % --- Track actual revenue and COGS for this year -----------------------
  actRevenueY = 0;
  actCOGSY    = 0;

  % --- Generate each order -----------------------------------------------
  for i = 1:nOrdersY

    productId = productId + 1;
    typeIdx   = typeAssignment(i);
    compIdx   = typeComponents{typeIdx};
    compQty   = typeQuantities{typeIdx};
    nComp     = length(compIdx);

    % Manufacturing timing
    mfgDays   = max(1, round(mfgMean + mfgStd * randn()));
    iMfgStart = bomStartInds(i);
    iMfgEnd   = min(nDates, iMfgStart + mfgDays);
    mfgStart  = allDates(iMfgStart);
    mfgFinish = allDates(iMfgEnd);
    productOrderDate(productId) = mfgStart;

    iDmMfgStart = getdmInd(mfgStart);
    iDmMfgEnd   = getdmInd(mfgFinish);

    % COGS in EUR for this order
    cogsEUR = 0;
    for j = 1:nComp
      cj = compIdx(j);
      priceProcCur = alpha * compPriceInit(cj);
      fxProcToEUR  = dm.fx{compIcur(cj), iCurFunctional}(iDmMfgStart);
      cogsEUR      = cogsEUR + priceProcCur * compQty(j) * fxProcToEUR;
    end

    % Revenue: selling price in EUR (inflation-adjusted)
    revenueEUR = sellPriceByYear(typeIdx, y);

    % Sales currency
    iSaleType  = curAssignment(i);
    curSaleStr = saleCurNames{iSaleType};
    iCurSale   = saleCurIcur(iSaleType);
    fxEURtoSale = dm.fx{iCurFunctional, iCurSale}(iDmMfgEnd);
    revenueSale = revenueEUR * fxEURtoSale;

    % Customer payment timing
    custPay     = max(7, round(custPayMean + custPayStd * randn()));
    invoiceDate = mfgFinish + 7;
    arDueDate   = invoiceDate + custPay;
    arWd = weekday(arDueDate);
    if arWd == 7, arDueDate = arDueDate - 1; end
    if arWd == 1, arDueDate = arDueDate - 2; end

    % Track actuals
    actRevenueY = actRevenueY + revenueEUR;
    actCOGSY    = actCOGSY    + cogsEUR;
    summTypeCounts(y, typeIdx) = summTypeCounts(y, typeIdx) + 1;
    summCurRevenue(y, iSaleType) = summCurRevenue(y, iSaleType) + revenueEUR;

    % --- Fill sales table ------------------------------------------------
    sa_fxAmt(productId)     = revenueSale;
    sa_localAmt(productId)  = revenueEUR;
    sa_costPrice(productId) = cogsEUR;
    sa_cur{productId}       = curSaleStr;

    % --- Fill AR table (invoice + payment) --------------------------------
    r1 = 2*(productId-1)+1;
    r2 = 2*(productId-1)+2;

    a_invoiceNum(r1) = productId;  a_txCode(r1) = 10;
    a_fxAmt(r1)      = revenueSale;
    a_cur{r1}        = curSaleStr;
    a_accDate(r1)    = invoiceDate;
    a_dueDate(r1)    = arDueDate;

    a_invoiceNum(r2) = productId;  a_txCode(r2) = 20;
    a_fxAmt(r2)      = -revenueSale;
    a_cur{r2}        = curSaleStr;
    a_dueDate(r2)    = arDueDate;
    a_accDate(r2)    = arDueDate;

    % --- Components: BOM rows + procurement + stock + AP -----------------
    for j = 1:nComp
      cj     = compIdx(j);
      qBuy   = compQty(j);
      curStr = compCurStr{cj};

      poId     = poId + 1;
      bomRowId = bomRowId + 1;

      % Procurement timing
      procLead  = max(5, round(procLeadMean + procLeadStd * randn()));
      iProcDate = max(1, iMfgStart - procLead);
      procDate  = allDates(iProcDate);

      % Supplier payment
      suppPay = max(1, round(suppPayMean + suppPayStd * randn()));
      apDue   = procDate + suppPay;
      apWd = weekday(apDue);
      if apWd == 7, apDue = apDue - 1; end
      if apWd == 1, apDue = apDue - 2; end

      % Prices
      compPrice       = alpha * compPriceInit(cj);
      totalAmtProcCur = compPrice * qBuy;

      % BOM row
      b_product(bomRowId)     = productId;
      b_compNum(bomRowId)     = cj;
      b_qty(bomRowId)         = qBuy;
      b_refOrder(bomRowId)    = 0;
      b_repDate(bomRowId)     = mfgStart;
      b_costPrice(bomRowId)   = compPrice;
      b_finishDate(bomRowId)  = mfgFinish;
      b_costPriceVal(bomRowId)= qBuy * compPrice;

      % Purchase order
      p_poNum(bomRowId)   = poId;
      p_itemNum(bomRowId) = cj;
      p_txCode(bomRowId)  = 40;
      p_cur{bomRowId}     = curStr;
      p_poNum1(bomRowId)  = poId;
      p_qty(bomRowId)     = qBuy;
      p_accDate(bomRowId) = procDate;
      p_dueDate(bomRowId) = apDue;
      p_amount(bomRowId)  = totalAmtProcCur;

      % Accounts payable (2 rows per PO)
      r1ap = 2*(poId-1)+1;
      r2ap = 2*(poId-1)+2;

      ap_invoiceNum(r1ap) = poId;  ap_txCode(r1ap) = 10;
      ap_fxAmt(r1ap)      = totalAmtProcCur;
      ap_cur{r1ap}        = curStr;
      ap_accDate(r1ap)    = procDate;
      ap_dueDate(r1ap)    = apDue;

      ap_invoiceNum(r2ap) = poId;  ap_txCode(r2ap) = 20;
      ap_fxAmt(r2ap)      = -totalAmtProcCur;
      ap_cur{r2ap}        = curStr;
      ap_accDate(r2ap)    = apDue;
      ap_dueDate(r2ap)    = apDue;

      % Stock transaction: procurement receipt (type 25)
      stockRowId = stockRowId + 1;
      s_itemNum(stockRowId) = cj;
      s_txType(stockRowId)  = 25;
      s_qty(stockRowId)     = qBuy;
      s_entDate(stockRowId) = procDate;
      s_ordNum(stockRowId)  = poId;

      % Stock transaction: manufacturing consumption (type 11)
      stockRowId = stockRowId + 1;
      s_itemNum(stockRowId) = cj;
      s_txType(stockRowId)  = 11;
      s_qty(stockRowId)     = -qBuy;
      s_entDate(stockRowId) = mfgStart;
      s_ordNum(stockRowId)  = productId;

    end  % components
  end  % orders in year

  % --- Cash management at year-end ---------------------------------------
  % Simplified: net cash = revenue received - COGS paid (in EUR terms)
  cashBalance = cashBalance + actRevenueY - actCOGSY;
  retainedCash = cashRetentionFrac * targetCOGS(y);
  dividend = max(0, cashBalance - retainedCash);
  cashBalance = cashBalance - dividend;

  % --- Store summary -----------------------------------------------------
  summActRevenue(y)  = actRevenueY;
  summActCOGS(y)     = actCOGSY;
  summNOrders(y)     = nOrdersY;
  summDividend(y)    = dividend;
  summCash(y)        = cashBalance;

end  % year loop

%% ========================================================================
%  BUILD TABLES & SAVE
%% ========================================================================

% Trim pre-allocated arrays to actual size
b_product    = b_product(1:bomRowId);     b_compNum     = b_compNum(1:bomRowId);
b_qty        = b_qty(1:bomRowId);         b_refOrder    = b_refOrder(1:bomRowId);
b_repDate    = b_repDate(1:bomRowId);     b_costPrice   = b_costPrice(1:bomRowId);
b_finishDate = b_finishDate(1:bomRowId);  b_costPriceVal= b_costPriceVal(1:bomRowId);

p_poNum   = p_poNum(1:bomRowId);    p_itemNum = p_itemNum(1:bomRowId);
p_txCode  = p_txCode(1:bomRowId);   p_cur     = p_cur(1:bomRowId);
p_poNum1  = p_poNum1(1:bomRowId);   p_qty     = p_qty(1:bomRowId);
p_accDate = p_accDate(1:bomRowId);  p_dueDate = p_dueDate(1:bomRowId);
p_amount  = p_amount(1:bomRowId);

nProducts = productId;

sa_invoiceNum = (1:nProducts)';  sa_itemNum = (1:nProducts)';
sa_fxAmt      = sa_fxAmt(1:nProducts);
sa_localAmt   = sa_localAmt(1:nProducts);
sa_costPrice  = sa_costPrice(1:nProducts);
sa_cur        = sa_cur(1:nProducts);

a_invoiceNum = a_invoiceNum(1:2*nProducts);  a_txCode = a_txCode(1:2*nProducts);
a_fxAmt      = a_fxAmt(1:2*nProducts);      a_cur    = a_cur(1:2*nProducts);
a_dueDate    = a_dueDate(1:2*nProducts);     a_accDate= a_accDate(1:2*nProducts);

ap_invoiceNum = ap_invoiceNum(1:2*poId);  ap_txCode = ap_txCode(1:2*poId);
ap_fxAmt      = ap_fxAmt(1:2*poId);      ap_cur    = ap_cur(1:2*poId);
ap_dueDate    = ap_dueDate(1:2*poId);     ap_accDate= ap_accDate(1:2*poId);

s_itemNum = s_itemNum(1:stockRowId);  s_txType = s_txType(1:stockRowId);
s_ohBal   = s_ohBal(1:stockRowId);   s_qty    = s_qty(1:stockRowId);
s_entDate = s_entDate(1:stockRowId);  s_ordNum = s_ordNum(1:stockRowId);
s_implOH  = s_implOH(1:stockRowId);

productOrderDate = productOrderDate(1:nProducts);

% --- Build tables --------------------------------------------------------

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

% --- Stock transactions: combine, sort, compute on-hand balance ----------
sNames = {'itemNumber','stockTransactionType','newOnHandBalance', ...
          'transactionQuantityBasicUM','entryDate','orderNumber','impliedOnHandBalance'};

s = table(s_itemNum, s_txType, s_ohBal, s_qty, s_entDate, s_ordNum, s_implOH, 'VariableNames', sNames);
[~, sortInd] = sort(s.entryDate);
s = s(sortInd, :);

for j = 1:nComponents
  ind = find(s.itemNumber == j);
  if ~isempty(ind)
    stock = cumsum(s.transactionQuantityBasicUM(ind));
    s.newOnHandBalance(ind)     = stock;
    s.impliedOnHandBalance(ind) = stock;
  end
end

% Fix weekend due-dates in purchase orders
wd = weekday(p.dueDate);
p.dueDate(wd==7) = p.dueDate(wd==7) - 1;
p.dueDate(wd==1) = p.dueDate(wd==1) - 2;

% --- Dictionaries --------------------------------------------------------
itemNumberDictionary    = cellstr(num2str((1:nComponents)', '%010.0f'));
productNumberDictionary = cellstr(num2str((1:nProducts)',   '%010.0f'));

% --- Costing table -------------------------------------------------------
c = table(cCostingData(:,1), cCostingData(:,2), cCostingData(:,3), cCostingData(:,4), ...
  'VariableNames', {'facility','itemNumber','costingDate','CostingSum1'});

%% ========================================================================
%  SAVE ALL FILES
%% ========================================================================

save(fullfile('simulatedData', 'costing'),              'c');
save(fullfile('simulatedData', 'BOM'),                  'b', 'productOrderDate');
save(fullfile('simulatedData', 'Sales'),                'sa');
save(fullfile('simulatedData', 'AccountsReceivable'),   'a');
save(fullfile('simulatedData', 'stockTransactions'),    's');
save(fullfile('simulatedData', 'purchaseOrder'),        'p');
save(fullfile('simulatedData', 'itemNumberDictionary'), 'itemNumberDictionary', 'productNumberDictionary');

ap = table(ap_invoiceNum, ap_txCode, ap_fxAmt, ap_cur, ap_dueDate, ap_accDate, ...
  'VariableNames', {'invoiceNumber','transactionCode','foreignCurrencyAmount','currency','dueDate','accountingDate'});
save(fullfile('simulatedData', 'AccountsPayable'), 'ap');

%% ========================================================================
%  VERBOSE YEAR-BY-YEAR SUMMARY
%% ========================================================================

if verbose
  % --- Main summary table ------------------------------------------------
  fprintf('\n=== Simulation Summary (seed=%d) ===\n', seed);
  fprintf('%-6s %10s %10s %7s %7s %7s %7s %7s %8s %10s\n', ...
    'Year', 'TargRevM', 'ActRevM', 'TargGM', 'ActGM', 'nOrds', 'Alpha', 'CashM', 'DividndM', 'A/B/C');
  fprintf('%s\n', repmat('-', 1, 100));
  for y = 1:nYears
    actGM = 100 * (1 - summActCOGS(y) / summActRevenue(y));
    splitStr = sprintf('%d/%d/%d', summTypeCounts(y,1), summTypeCounts(y,2), summTypeCounts(y,3));
    fprintf('%-6d %10.1f %10.1f %6.1f%% %6.1f%% %7d %7.3f %8.1f %10.1f   %s\n', ...
      simYears(y), ...
      targetRevenue(y)/1e6, ...
      summActRevenue(y)/1e6, ...
      grossMarginPct(y), ...
      actGM, ...
      summNOrders(y), ...
      alphaByYear(y), ...
      summCash(y)/1e6, ...
      summDividend(y)/1e6, ...
      splitStr);
  end
  fprintf('%s\n', repmat('-', 1, 100));
  fprintf('Total products: %d  |  Total POs: %d  |  Date range: %s to %s\n', ...
    nProducts, poId, datestr(allDates(1)), datestr(allDates(end)));

  % --- Sales currency exposure table -------------------------------------
  fprintf('\n=== Sales Currency Exposure (actual %% of revenue in EUR) ===\n');
  fprintf('%-6s', 'Year');
  for c = 1:length(saleCurNames)
    fprintf(' %6s', saleCurNames{c});
  end
  fprintf('\n%s\n', repmat('-', 1, 6 + 7*length(saleCurNames)));
  for y = 1:nYears
    fprintf('%-6d', simYears(y));
    totRev = summActRevenue(y);
    for c = 1:length(saleCurNames)
      fprintf(' %5.1f%%', 100 * summCurRevenue(y,c) / totRev);
    end
    fprintf('\n');
  end
  fprintf('%-6s', 'Target');
  for c = 1:length(saleCurNames)
    fprintf(' %5.1f%%', saleExposurePct(c));
  end
  fprintf('\n');
end

end % function createMatFilesSim
