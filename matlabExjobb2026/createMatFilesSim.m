function createMatFilesSim(dm, seed, verbose, dataFolder, sandvikArrays, timingOverride)
% createMatFilesSim  Generate synthetic multi-currency transaction data.
%
%   createMatFilesSim(dm, seed, verbose, dataFolder, sandvikArrays, timingOverride)
%
%   dm              - market data struct from createDataMarket (provides FX rates)
%   seed            - RNG seed for reproducibility (default 1)
%   verbose         - print year-by-year summary to console (default true)
%   dataFolder      - output folder for .mat files (default 'simulatedData')
%                     Use worker-specific folders when running under parfor.
%   sandvikArrays   - optional struct with fields revenueGrowthPct and
%                     grossMarginPct (pre-loaded in runMC to avoid reading
%                     the Excel file on every MC iteration).  If empty or
%                     omitted the file is read as normal.
%   timingOverride  - optional struct with any subset of fields:
%                       procLeadMean / procLeadStd
%                       mfgMean      / mfgStd
%                       custPayMean  / custPayStd
%                       suppPayMean  / suppPayStd
%                     Fields present override the baseline Table 4.7 values
%                     (used by runSensitivity to sweep timing parameters).
%
% The function generates a 20-year transaction history (2006-2025) for a
% simulated manufacturing subsidiary.  Revenue and gross margin are
% calibrated year by year to Sandvik's reported figures (Tables 4.3-4.4).
% Component prices are scaled annually so that total COGS matches the
% target margin.  The function writes all .mat files to dataFolder/ and
% is designed to be called repeatedly inside a Monte Carlo loop (runMC.m).

if nargin < 2 || isempty(seed),          seed          = 1;              end
if nargin < 3 || isempty(verbose),        verbose       = true;           end
if nargin < 4 || isempty(dataFolder),     dataFolder    = 'simulatedData'; end
if nargin < 5,                            sandvikArrays = [];             end
if nargin < 6,                            timingOverride = [];            end

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
simStartYear = 2007;  % Data back to 2005 when FX/yield data is fully extended

% --- Revenue: start value and annual growth rates (Tables 4.3-4.4) -------
%   allYears = 2005:2025 (21 elements); index 1=2005, 2=2006, 3=2007, ..., 21=2025
%   2005 (index 1): base year — growth = NaN, GM kept as placeholder
%   2006 (index 2): no Sandvik growth data (no 2005 base) — keep placeholder
%   2007-2025 (indices 3-21): loaded from Sandvik annual report data below
startRevenue     = 500e6;   % EUR, year 2005 (base year for compounding)
revenueGrowthPct = [NaN, 18.2, NaN(1,19)];  % 2005-2006 hardcoded; 2007-2025 loaded below
grossMarginPct   = [42.5, 43.1, NaN(1,19)]; % 2005-2006 hardcoded; 2007-2025 loaded below

% --- Load actual Sandvik revenue growth and gross margin (2007-2025) ------
% Pre-loaded data (sandvikArrays) is used when called from runMC to avoid
% reading the Excel file on every MC iteration (slow readcell call).
if ~isempty(sandvikArrays)
  revenueGrowthPct = sandvikArrays.revenueGrowthPct;
  grossMarginPct   = sandvikArrays.grossMarginPct;
else
  % File: marketData/202605_Sandvik_Data.xlsx, sheet: Income Statement
  % Column layout: col 1 = field name, col 2 = 2006, col 3 = 2007, ..., col 21 = 2025
  sandvikFile = fullfile('marketData', '202605_Sandvik_Data.xlsx');
  if isfile(sandvikFile)
    raw = readcell(sandvikFile, 'Sheet', 'Income Statement');
    revRow = find(cellfun(@(x) ischar(x) && strcmp(x, 'Revenue growth, %'), raw(:,1)));
    gmRow  = find(cellfun(@(x) ischar(x) && strcmp(x, 'Gross Margin'),      raw(:,1)));
    if ~isempty(revRow) && ~isempty(gmRow)
      for col = 3:21  % col 3 = 2007, col 21 = 2025 (matches allYears index)
        v = raw{revRow, col};
        if isnumeric(v) && ~isnan(v), revenueGrowthPct(col) = v * 100; end
        v = raw{gmRow, col};
        if isnumeric(v) && ~isnan(v), grossMarginPct(col)   = v * 100; end
      end
      fprintf('Loaded Sandvik revenue growth and gross margin (2007-2025) from %s\n', sandvikFile);
    else
      error('Could not find Revenue growth or Gross Margin rows in %s', sandvikFile);
    end
  else
    error('Sandvik data file not found: %s\nPlace 202605_Sandvik_Data.xlsx in the marketData/ folder.', sandvikFile);
  end
end

% --- Inflation per year (%) - placeholder, update with actual data -------
inflationPct = 2.0 * ones(1, 21);  % 2% flat placeholder

% --- Base selling prices per product type (EUR, year 2005) ---------------
%
%   ACTUAL MODE  ~100-170 orders/year  (MC production run — realistic volume,
%                                       good statistical convergence, use with K>=100)
%   NORMAL MODE  ~100-170 orders/year  (identical prices to actual; kept for reference)
%   TEST MODE    ~20-30 orders/year    (manual verification — few transactions,
%                                       easy to trace but poor statistical coverage)
%
baseSellPriceEUR = [1000000, 5000000, 20000000];      % NORMAL MODE
% baseSellPriceEUR = [5000000, 25000000, 100000000];    % TEST MODE (×5 prices → ~20 orders/yr)

% --- Product mix probabilities (by unit count) ---------------------------
productMixWeights = [0.60, 0.25, 0.15];  % Type A, B, C

% --- Sales currency exposure (Table 4.5; INR dropped due to limited yield data)
% Weights will auto-normalize to 100% in the generation loop
saleCurNames   = {'USD','EUR','AUD','CAD','ZAR','CNY'};
saleExposurePct = [39,   31,   12,    8,    6,    4  ];

% --- Cash management -----------------------------------------------------
cashRetentionFrac = 0.10;  % retain 10% of prior year COGS & sweep rest to parent

% --- Timing parameters (Table 4.7) --------------------------------------
procLeadMean = 45;  procLeadStd = 10;   % days: procurement lead time (order → delivery)
mfgMean      = 20;  mfgStd      =  5;   % days: manufacturing duration
custPayMean  = 45;  custPayStd  = 15;   % days: customer payment delay
suppPayMean  = 60;  suppPayStd  = 15;   % days: supplier payment delay

% Apply runSensitivity overrides (field-by-field; absent fields keep baseline)
if ~isempty(timingOverride)
  if isfield(timingOverride, 'procLeadMean'), procLeadMean = timingOverride.procLeadMean; end
  if isfield(timingOverride, 'procLeadStd'),  procLeadStd  = timingOverride.procLeadStd;  end
  if isfield(timingOverride, 'mfgMean'),      mfgMean      = timingOverride.mfgMean;      end
  if isfield(timingOverride, 'mfgStd'),       mfgStd       = timingOverride.mfgStd;       end
  if isfield(timingOverride, 'custPayMean'),  custPayMean  = timingOverride.custPayMean;  end
  if isfield(timingOverride, 'custPayStd'),   custPayStd   = timingOverride.custPayStd;   end
  if isfield(timingOverride, 'suppPayMean'),  suppPayMean  = timingOverride.suppPayMean;  end
  if isfield(timingOverride, 'suppPayStd'),   suppPayStd   = timingOverride.suppPayStd;   end
end

%% ========================================================================
%  COMPONENT & BOM DEFINITIONS  (fixed structure)
%% ========================================================================

nComponents   = 10;
compCurStr    = {'USD','EUR','EUR','USD','CNY','EUR','USD','USD','USD','CNY'};
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

% Slice index: simStartYear (2007) is the revenue base year
iStart = find(allYears == simStartYear);

% Compute revenue: startRevenue is the base for simStartYear (2007),
% then compound forward using actual Sandvik growth rates.
allRevenue = zeros(1, length(allYears));
allRevenue(iStart) = startRevenue;   % 2007 = 500 MEUR base
for y = iStart+1:length(allYears)
  allRevenue(y) = allRevenue(y-1) * (1 + revenueGrowthPct(y)/100);
end
simYears = allYears(iStart:end);

% Cap to years that actually have data in dm.dates (prevents out-of-range years
% from triggering the yearStartIdx/yearEndIdx=1 fallback, which would place all
% orders for that year on allDates(2) = the second business day of the PA period).
[yr_end_dm, ~, ~] = datevec(dm.dates(end));
simYears = simYears(simYears <= yr_end_dm);
nYears   = length(simYears);
iEnd     = iStart + nYears - 1;  % inclusive end index into allYears arrays

% Slice all calibration arrays to match
revenueGrowthPct = revenueGrowthPct(iStart:iEnd);
grossMarginPct   = grossMarginPct(iStart:iEnd);
inflationPct     = inflationPct(iStart:iEnd);

% Revenue targets (compounded from 2005 base, sliced to sim window)
targetRevenue = allRevenue(iStart:iEnd);

% COGS targets
targetCOGS = targetRevenue .* (1 - grossMarginPct/100);

% Selling prices per type per year (inflation-adjusted from 2005 base)
allInflation = 2.0 * ones(1, length(allYears));  % full 2005-2025 inflation
allInflation(iStart:iEnd) = inflationPct;         % overwrite with sliced values
allSellPrice = zeros(nTypes, length(allYears));
for t = 1:nTypes
  allSellPrice(t, 1) = baseSellPriceEUR(t);
  for y = 2:length(allYears)
    allSellPrice(t, y) = allSellPrice(t, y-1) * (1 + allInflation(y)/100);
  end
end
sellPriceByYear = allSellPrice(:, iStart:iEnd);

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
  % Average FX rates over the full calendar year (BOY to EOY).
  % Using the annual average rather than the BOY snapshot means alpha is
  % calibrated to match actual COGS in expectation: orders are spread
  % uniformly across the year, so their average FX rate ≈ annual average.
  % This eliminates the systematic GM gap caused by intra-year FX drift.
  iDmBOY = getdmInd(allDates(yearStartIdx(y)));
  iDmEOY = getdmInd(allDates(yearEndIdx(y)));

  % Compute COGS per unit at alpha=1 for each product type
  cogsPerUnit = zeros(1, nTypes);
  for t = 1:nTypes
    compIdx = typeComponents{t};
    compQty = typeQuantities{t};
    for j = 1:length(compIdx)
      cj = compIdx(j);
      fxSeries = dm.fx{compIcur(cj), iCurFunctional}(iDmBOY:iDmEOY);
      fxAvg    = mean(fxSeries, 'omitnan');
      cogsPerUnit(t) = cogsPerUnit(t) + compPriceInit(cj) * compQty(j) * fxAvg;
    end
  end

  % Exact type counts (deterministic since type assignment uses fixed counts)
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
b_poNum      = zeros(nTotalPO, 1);  % stable link from BOM row → PO row

% Purchase orders
p_poNum     = zeros(nTotalPO, 1);  p_itemNum  = zeros(nTotalPO, 1);
p_txCode    = zeros(nTotalPO, 1);  p_cur      = cell(nTotalPO, 1);
p_poNum1    = zeros(nTotalPO, 1);  p_qty      = zeros(nTotalPO, 1);
p_orderDate = zeros(nTotalPO, 1);  % NEW: PO placed (= procDate)
p_accDate   = zeros(nTotalPO, 1);  p_dueDate  = zeros(nTotalPO, 1);
p_amount    = zeros(nTotalPO, 1);

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
summCurRevenue  = zeros(nYears, length(saleCurNames)); % revenue per currency per year (EUR)
summCurCOGS     = zeros(nYears, length(saleCurNames)); % COGS per currency per year (EUR)
dividendEvents  = zeros(0, 2);                     % [date, amount_EUR] per sweep

for y = 1:nYears

  alpha = alphaByYear(y);
  nOrdersY = nOrdersPerYear(y);

  % --- Determine product types for this year (fixed counts, random order) -
  % Fix the count of each type to match productMixWeights exactly (same
  % approach as currency assignment below).  This ensures that annual revenue
  % in EUR is deterministic across MC seeds — only the ordering and timing
  % of orders varies.  Without this, the ~6.6M EUR per-order price std-dev
  % across types gives ~13% CV in annual revenue (too noisy for MC error terms).
  targetTypeCount = round(productMixWeights * nOrdersY);
  targetTypeCount(end) = nOrdersY - sum(targetTypeCount(1:end-1));  % fix rounding
  typeAssignment = zeros(nOrdersY, 1);
  idx = 1;
  for t = 1:nTypes
    typeAssignment(idx:idx+targetTypeCount(t)-1) = t;
    idx = idx + targetTypeCount(t);
  end
  typeAssignment = typeAssignment(randperm(nOrdersY));

  % --- Assign sales currencies to match revenue exposure targets ----------
  % Assign by REVENUE (not by order count) so that the actual % of revenue
  % per currency matches saleExposurePct regardless of product-type mix.
  % Without this, a small currency (e.g. ZAR at 5% of orders) that happens
  % to land a Type C order (20M EUR) will show 20%+ of revenue that year.
  %
  % Algorithm: shuffle order indices, then greedily assign each order to
  % the currency that is most below its revenue target. This ensures revenue
  % shares are matched exactly while keeping the timing assignment random.
  saleWeightsNorm = saleExposurePct / sum(saleExposurePct);
  orderRevenue    = arrayfun(@(t) sellPriceByYear(t, y), typeAssignment);
  targetRevByCur  = saleWeightsNorm * sum(orderRevenue);
  cumRevByCur     = zeros(1, length(saleCurNames));
  curAssignment   = zeros(nOrdersY, 1);
  permIdx         = randperm(nOrdersY);
  for k = 1:nOrdersY
    i = permIdx(k);
    [~, bestCur] = max(targetRevByCur - cumRevByCur);
    curAssignment(i) = bestCur;
    cumRevByCur(bestCur) = cumRevByCur(bestCur) + orderRevenue(i);
  end

  % --- Assign purchase currencies to match same exposure as sales ----------
  % Each order gets one purchase currency; all its AP entries use that currency.
  % Greedy algorithm by COGS value (same approach as sales by revenue).
  orderCOGSbase      = arrayfun(@(t) sum(typeQuantities{t} .* compPriceInit(typeComponents{t})), typeAssignment);
  targetCOGSbyCur    = saleWeightsNorm * sum(orderCOGSbase);
  cumCOGSbyCur       = zeros(1, length(saleCurNames));
  purchCurAssignment = zeros(nOrdersY, 1);
  permIdxP           = randperm(nOrdersY);
  for kp = 1:nOrdersY
    ip = permIdxP(kp);
    [~, bestCur] = max(targetCOGSbyCur - cumCOGSbyCur);
    purchCurAssignment(ip) = bestCur;
    cumCOGSbyCur(bestCur)  = cumCOGSbyCur(bestCur) + orderCOGSbase(ip);
  end

  % --- Manufacturing start dates: uniform random within year -------------
  % bufferStart: year 1 — procurement must not predate dm.dates(1)
  % procBuf: all years — keep procurement within same calendar year to avoid
  %   component inventory spikes at year boundaries (procLead can be up to 75 days)
  % bufferEnd: last year — customer payment must not exceed dm.dates(end)
  bufferStart = procLeadMean + 3*procLeadStd + mfgMean + 3*mfgStd + 10;
  procBuf     = procLeadMean + 3*procLeadStd;
  bufferEnd   = custPayMean  + 3*custPayStd  + 10;

  iYearStart = yearStartIdx(y);
  iYearEnd   = yearEndIdx(y);

  if y == 1
    iValidStart = iYearStart + round(bufferStart / 1.4);
  else
    iValidStart = iYearStart + procBuf;
  end
  if y == nYears
    iValidEnd = iYearEnd - round(bufferEnd / 1.4);
  else
    iValidEnd = iYearEnd;
  end

  if iValidStart > iValidEnd
    % Narrow year — use full year range (some payments may spill over)
    iValidStart = iYearStart;
    iValidEnd   = iYearEnd;
  end

  % Never allow mfgStart = allDates(1): that date equals firstDate in buildPA,
  % which would incorrectly assign h0=1 (pre-period inventory) instead of xBI.
  iValidStart = max(iValidStart, 2);
  iValidEnd   = max(iValidEnd, iValidStart);

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
    productOrderDate(productId) = Inf;  % will be set to min(procDate) across components below

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
    if arWd == 7, arDueDate = arDueDate + 2; end  % Sat -> Mon
    if arWd == 1, arDueDate = arDueDate + 1; end  % Sun -> Mon
    while arDueDate <= dm.dates(end)
      idx = arDueDate - dm.dates(1) + 1;
      if idx >= 1 && idx <= length(dm.indAllDates) && dm.indAllDates(idx) > 0, break; end
      arDueDate = arDueDate + 1;
    end

    % Track actuals
    actRevenueY = actRevenueY + revenueEUR;
    actCOGSY    = actCOGSY    + cogsEUR;
    summTypeCounts(y, typeIdx) = summTypeCounts(y, typeIdx) + 1;
    summCurRevenue(y, iSaleType) = summCurRevenue(y, iSaleType) + revenueEUR;
    iPurchType = purchCurAssignment(i);
    summCurCOGS(y, iPurchType)  = summCurCOGS(y, iPurchType)  + cogsEUR;

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

      poId     = poId + 1;
      bomRowId = bomRowId + 1;

      % Procurement timing
      procLead         = max(5, round(procLeadMean + procLeadStd * randn()));
      iProcDate        = max(2, iMfgStart - procLead);  % never at allDates(1)=firstDate → avoids component h0
      procDate         = allDates(iProcDate);            % order date (PO placed)
      procDeliveryDate = mfgStart;                       % delivery date (= mfgStart for now; decouple when safety stock introduced)

      % Track earliest component order date for BOM start
      productOrderDate(productId) = min(productOrderDate(productId), procDate);

      % Supplier payment
      suppPay = max(1, round(suppPayMean + suppPayStd * randn()));
      apDue   = procDeliveryDate + suppPay;
      apWd = weekday(apDue);
      if apWd == 7, apDue = apDue + 2; end  % Sat -> Mon (ensures apDue > procDate)
      if apWd == 1, apDue = apDue + 1; end  % Sun -> Mon
      while apDue <= dm.dates(end)
        idx = apDue - dm.dates(1) + 1;
        if idx >= 1 && idx <= length(dm.indAllDates) && dm.indAllDates(idx) > 0, break; end
        apDue = apDue + 1;
      end

      % Prices — convert to order-level purchase currency
      iPurchIcur      = saleCurIcur(purchCurAssignment(i));
      purchCurStr     = saleCurNames{purchCurAssignment(i)};
      compPrice       = alpha * compPriceInit(cj);
      fxCjToEUR       = dm.fx{compIcur(cj), iCurFunctional}(iDmMfgStart);
      fxEURtoPurch    = dm.fx{iCurFunctional, iPurchIcur}(iDmMfgStart);
      totalAmtProcCur = compPrice * qBuy * fxCjToEUR * fxEURtoPurch;

      % BOM row
      % actualFinishDate = procDeliveryDate (= mfgStart): each component BOM
      % covers only the shipping window (procDate → mfgStart). After delivery
      % the AP bond takes over the cost-side FX tracking. The Component BOM
      % carries a single negative cash flow at procDeliveryDate in proc currency.
      b_product(bomRowId)     = productId;
      b_compNum(bomRowId)     = cj;
      b_qty(bomRowId)         = qBuy;
      b_refOrder(bomRowId)    = 0;
      b_repDate(bomRowId)     = mfgStart;
      b_costPrice(bomRowId)   = compPrice;
      b_finishDate(bomRowId)  = procDeliveryDate;  % delivery (= mfgStart)
      b_costPriceVal(bomRowId)= qBuy * compPrice;
      b_poNum(bomRowId)       = poId;              % link BOM row → PO

      % Purchase order
      p_poNum(bomRowId)     = poId;
      p_itemNum(bomRowId)   = cj;
      p_txCode(bomRowId)    = 40;
      p_cur{bomRowId}       = purchCurStr;
      p_poNum1(bomRowId)    = poId;
      p_qty(bomRowId)       = qBuy;
      p_orderDate(bomRowId) = procDate;          % PO placed (Component BOM start)
      p_accDate(bomRowId)   = procDeliveryDate;  % delivery / AP bond start
      p_dueDate(bomRowId)   = apDue;             % AP bond maturity
      p_amount(bomRowId)    = totalAmtProcCur;

      % Accounts payable (2 rows per PO)
      r1ap = 2*(poId-1)+1;
      r2ap = 2*(poId-1)+2;

      ap_invoiceNum(r1ap) = poId;  ap_txCode(r1ap) = 10;
      ap_fxAmt(r1ap)      = totalAmtProcCur;
      ap_cur{r1ap}        = purchCurStr;
      ap_accDate(r1ap)    = procDeliveryDate;
      ap_dueDate(r1ap)    = apDue;

      ap_invoiceNum(r2ap) = poId;  ap_txCode(r2ap) = 20;
      ap_fxAmt(r2ap)      = -totalAmtProcCur;
      ap_cur{r2ap}        = purchCurStr;
      ap_accDate(r2ap)    = apDue;
      ap_dueDate(r2ap)    = apDue;

      % Stock transaction: procurement receipt (type 25)
      stockRowId = stockRowId + 1;
      s_itemNum(stockRowId) = cj;
      s_txType(stockRowId)  = 25;
      s_qty(stockRowId)     = qBuy;
      s_entDate(stockRowId) = procDeliveryDate;
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

  % Record dividend event (date = last business day of the year, for
  % downstream balance sheet tracking in the industry methods)
  if dividend > 0
    divDate = allDates(iYearEnd);
    dividendEvents(end+1, :) = [divDate, dividend]; %#ok<AGROW>
  end

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
b_poNum      = b_poNum(1:bomRowId);

p_poNum     = p_poNum(1:bomRowId);     p_itemNum  = p_itemNum(1:bomRowId);
p_txCode    = p_txCode(1:bomRowId);    p_cur      = p_cur(1:bomRowId);
p_poNum1    = p_poNum1(1:bomRowId);    p_qty      = p_qty(1:bomRowId);
p_orderDate = p_orderDate(1:bomRowId); p_accDate  = p_accDate(1:bomRowId);
p_dueDate   = p_dueDate(1:bomRowId);   p_amount   = p_amount(1:bomRowId);

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

b = table(b_product, b_compNum, b_qty, b_refOrder, b_repDate, b_costPrice, b_finishDate, b_costPriceVal, b_poNum, ...
  'VariableNames', {'product','componentNumber','quantity','referenceOrderNumber', ...
                    'reportingDate','costPrice','actualFinishDate','CostPriceValue','purchaseOrderNumber'});

p = table(p_poNum, p_itemNum, p_txCode, p_cur, p_poNum1, p_qty, p_orderDate, p_accDate, p_dueDate, p_amount, ...
  'VariableNames', {'purchaseOrderNumber','itemNumber','transactionCode','currency', ...
                    'purchaseOrderNumber_1','invoicedQuantityAlternateUM','orderDate','accountingDate','dueDate','lineAmountOrderCurrency'});

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

% Fix weekend due-dates in purchase orders (forward to Monday, not back to Friday)
wd = weekday(p.dueDate);
p.dueDate(wd==7) = p.dueDate(wd==7) + 2;
p.dueDate(wd==1) = p.dueDate(wd==1) + 1;

% --- Dictionaries --------------------------------------------------------
itemNumberDictionary    = cellstr(num2str((1:nComponents)', '%010.0f'));
productNumberDictionary = cellstr(num2str((1:nProducts)',   '%010.0f'));

% --- Costing table -------------------------------------------------------
c = table(cCostingData(:,1), cCostingData(:,2), cCostingData(:,3), cCostingData(:,4), ...
  'VariableNames', {'facility','itemNumber','costingDate','CostingSum1'});

%% ========================================================================
%  SAVE ALL FILES
%% ========================================================================

% Ensure the output folder exists (git does not track empty directories,
% so simulatedData/ may be absent after a fresh clone or pull).
if ~exist(dataFolder, 'dir')
  mkdir(dataFolder);
end

save(fullfile(dataFolder, 'costing'),              'c');
save(fullfile(dataFolder, 'BOM'),                  'b', 'productOrderDate');
save(fullfile(dataFolder, 'Sales'),                'sa');
save(fullfile(dataFolder, 'AccountsReceivable'),   'a');
save(fullfile(dataFolder, 'stockTransactions'),    's');
save(fullfile(dataFolder, 'purchaseOrder'),        'p');
save(fullfile(dataFolder, 'itemNumberDictionary'), 'itemNumberDictionary', 'productNumberDictionary');

ap = table(ap_invoiceNum, ap_txCode, ap_fxAmt, ap_cur, ap_dueDate, ap_accDate, ...
  'VariableNames', {'invoiceNumber','transactionCode','foreignCurrencyAmount','currency','dueDate','accountingDate'});
save(fullfile(dataFolder, 'AccountsPayable'), 'ap');

% Dividend events for industry-method balance sheet tracking (cash sweeps to parent)
save(fullfile(dataFolder, 'dividendEvents'), 'dividendEvents');

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

  % --- Net currency exposure table (sales - COGS, as % of revenue) -------
  fprintf('\n=== Net Currency Exposure (sales minus procurement, %% of revenue) ===\n');
  fprintf('%-6s', 'Year');
  for c = 1:length(saleCurNames)
    fprintf(' %6s', saleCurNames{c});
  end
  fprintf('\n%s\n', repmat('-', 1, 6 + 7*length(saleCurNames)));
  for y = 1:nYears
    fprintf('%-6d', simYears(y));
    totRev = summActRevenue(y);
    for c = 1:length(saleCurNames)
      netExp = (summCurRevenue(y,c) - summCurCOGS(y,c)) / totRev;
      fprintf(' %5.1f%%', 100 * netExp);
    end
    fprintf('\n');
  end
  avgGM = mean(grossMarginPct);
  fprintf('%-6s', 'Target');
  for c = 1:length(saleCurNames)
    fprintf(' %5.1f%%', avgGM * saleExposurePct(c) / 100);
  end
  fprintf('\n');
end

end % function createMatFilesSim
