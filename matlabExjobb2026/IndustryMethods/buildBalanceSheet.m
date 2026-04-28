function bs = buildBalanceSheet(dm, dc)
% buildBalanceSheet  Build daily balance sheet in EUR (functional currency).
%
%   bs = buildBalanceSheet(dm, dc)
%
% Produces daily time series of:
%   bs.dates         [M x 1]       - business day dates
%   bs.AR_face       [M x nCur]    - AR face value per currency (in transaction cur)
%   bs.AP_face       [M x nCur]    - AP face value per currency (in transaction cur)
%   bs.AR_EUR        [M x 1]       - AR total in EUR at daily rate
%   bs.AP_EUR        [M x 1]       - AP total in EUR at daily rate
%   bs.B_I           [M x 1]       - Inventory in EUR (historical cost, weighted avg)
%   bs.B_W           [M x 1]       - WIP in EUR (historical cost)
%   bs.B_C           [M x 1]       - Cash in EUR
%   bs.B_N           [M x 1]       - Net assets = B_I + B_W + AR_EUR - AP_EUR + B_C
%
% Inventory uses weighted-average cost method: components enter at historical
% EUR cost (procurement-date rate); consumption removes at current weighted
% average cost per unit.

M   = length(dm.dates);
nCur = length(dm.cName);
iCurFunctional = find(ismember(dm.cName, 'EUR'));

bs.dates = dm.dates;

%% ========================================================================
%  AR face values per currency  (eq 4.5 with face-value interpretation)
%% ========================================================================

bs.AR_face = zeros(M, nCur);

% dc.a has paired code 10 (invoice) / code 20 (payment) rows
invRows = find(dc.a.transactionCode == 10);
for k = 1:length(invRows)
  r1 = invRows(k);
  invNum = dc.a.invoiceNumber(r1);
  c      = dc.a.iCur(r1);
  amt    = dc.a.foreignCurrencyAmount(r1);
  tD     = dc.a.accountingDate(r1);           % delivery/invoice date

  % Find matching payment row
  r2 = find(dc.a.transactionCode == 20 & dc.a.invoiceNumber == invNum, 1);
  if isempty(r2)
    tP = dm.dates(end) + 1;                   % unsettled so it stays open
  else
    tP = dc.a.accountingDate(r2);
  end

  % Find date indices in dm.dates
  i1 = find(dm.dates >= tD, 1, 'first');
  i2 = find(dm.dates >= tP, 1, 'first');
  if isempty(i1), continue; end
  if isempty(i2), i2 = M + 1; end             % payment after data range

  % AR is outstanding from delivery (inclusive) to payment (exclusive)
  bs.AR_face(i1:i2-1, c) = bs.AR_face(i1:i2-1, c) + amt;
end

%% ========================================================================
%  AP face values per currency
%% ========================================================================

bs.AP_face = zeros(M, nCur);

apRows = find(dc.ap.transactionCode == 10);
for k = 1:length(apRows)
  r1     = apRows(k);
  apNum  = dc.ap.invoiceNumber(r1);
  c      = dc.ap.iCur(r1);
  amt    = dc.ap.foreignCurrencyAmount(r1);   % positive value (obligation)
  tD     = dc.ap.accountingDate(r1);          % procurement/goods received

  r2 = find(dc.ap.transactionCode == 20 & dc.ap.invoiceNumber == apNum, 1);
  if isempty(r2)
    tP = dm.dates(end) + 1;
  else
    tP = dc.ap.accountingDate(r2);
  end

  i1 = find(dm.dates >= tD, 1, 'first');
  i2 = find(dm.dates >= tP, 1, 'first');
  if isempty(i1), continue; end
  if isempty(i2), i2 = M + 1; end

  bs.AP_face(i1:i2-1, c) = bs.AP_face(i1:i2-1, c) + amt;
end

%% ========================================================================
%  AR and AP in EUR at daily rate  (for balance sheet display)
%% ========================================================================

bs.AR_EUR = zeros(M, 1);
bs.AP_EUR = zeros(M, 1);
for c = 1:nCur
  if c == iCurFunctional
    fx = ones(M, 1);
  else
    fx = dm.fx{c, iCurFunctional};
    if isempty(fx), fx = zeros(M, 1); end
  end
  bs.AR_EUR = bs.AR_EUR + bs.AR_face(:, c) .* fx;
  bs.AP_EUR = bs.AP_EUR + bs.AP_face(:, c) .* fx;
end

%% ========================================================================
%  Inventory per component (weighted-average cost in EUR)
%% ========================================================================

nComp = length(dc.itemNumbers);
inv_qty = zeros(M, nComp);
inv_EUR = zeros(M, nComp);

% Helper: convert a datenum to the corresponding row index in dm.dates
% (first day >= given date). Returns 0 if date is after data range.
dateIdx = @(d) find(dm.dates >= d, 1, 'first');

for cj = 1:nComp
  % Collect all stock events for this component
  idxRec = find(dc.s.itemNumber == cj & dc.s.stockTransactionType == 25);  % receipts
  idxCon = find(dc.s.itemNumber == cj & dc.s.stockTransactionType == 11);  % consumption

  events = [];                          % [dateIdx, type(25/11), qty, poNum]
  for k = 1:length(idxRec)
    r = idxRec(k);
    idx = dateIdx(dc.s.entryDate(r));
    if isempty(idx), continue; end
    events(end+1, :) = [idx, 25, dc.s.transactionQuantityBasicUM(r), dc.s.orderNumber(r)];  %#ok<AGROW>
  end
  for k = 1:length(idxCon)
    r = idxCon(k);
    idx = dateIdx(dc.s.entryDate(r));
    if isempty(idx), continue; end
    events(end+1, :) = [idx, 11, -dc.s.transactionQuantityBasicUM(r), dc.s.orderNumber(r)];  %#ok<AGROW>
    % Note: consumption qty in dc.s is negative; we store positive qty removed
  end

  if isempty(events), continue; end
  events = sortrows(events, 1);         % sort by date index

  current_qty = 0;
  current_EUR = 0;
  last_idx    = 1;

  for e = 1:size(events, 1)
    idx = events(e, 1);
    typ = events(e, 2);
    qty = events(e, 3);
    pon = events(e, 4);

    % Fill values from last_idx up to idx-1 with current state
    if last_idx <= idx - 1
      inv_qty(last_idx:idx-1, cj) = current_qty;
      inv_EUR(last_idx:idx-1, cj) = current_EUR;
    end

    if typ == 25   % receipt: add at historical EUR cost
      poRow = find(dc.p.purchaseOrderNumber == pon, 1);
      if isempty(poRow), continue; end
      cost_FX = dc.p.lineAmountOrderCurrency(poRow);   % in procurement currency
      iCur    = dc.p.iCur(poRow);
      if iCur == iCurFunctional
        fxRate = 1;
      else
        fxRate = dm.fx{iCur, iCurFunctional}(idx);
      end
      cost_EUR = cost_FX * fxRate;
      current_qty = current_qty + qty;
      current_EUR = current_EUR + cost_EUR;

    else           % typ == 11: consumption at weighted-average cost
      if current_qty > 0
        avg_cost = current_EUR / current_qty;
      else
        avg_cost = 0;
      end
      current_qty = current_qty - qty;
      current_EUR = current_EUR - qty * avg_cost;
    end

    last_idx = idx;
  end

  % Tail fill after last event
  inv_qty(last_idx:end, cj) = current_qty;
  inv_EUR(last_idx:end, cj) = current_EUR;
end

bs.B_I = sum(inv_EUR, 2);              % total inventory in EUR

%% ========================================================================
%  WIP per product (EUR, historical cost)
%% ========================================================================

nProd = length(dc.productNumbers);
bs.B_W = zeros(M, 1);

% For each product: WIP accumulates from earliest component consumption
% (dc.s type 11 with orderNumber = productId) to delivery date.
% At consumption: value added = qty * weighted_avg_cost at that moment.
% At delivery: WIP cleared (product moves to COGS).

% Delivery date = AR invoice date (dc.a code 10 accountingDate).
% Using the INVOICE date (mfgFinish+7 in the simulation), not actualFinishDate,
% ensures that WIP release and COGS recognition happen on the SAME day.
% That is required for the balance-sheet / P&L identity ΔB^N = I^N to hold
% within each reporting period.

productDeliveryDate = nan(nProd, 1);
for pIdx = 1:nProd
  prodNum = dc.productNumbers(pIdx);
  % Invoice number = product number (per simulation convention)
  r1 = find(dc.a.transactionCode == 10 & dc.a.invoiceNumber == prodNum, 1);
  if ~isempty(r1)
    productDeliveryDate(pIdx) = dc.a.accountingDate(r1);
  end
end

% Re-process consumption events, this time also accumulating into WIP per product
% We need the same weighted-avg inventory logic we just computed, but now we
% want the EUR cost at each consumption event.

% Track WIP value per product as a running sum, building on the fly
wip_per_product = zeros(nProd, 1);
% Earliest consumption date per product (when WIP starts)
wip_start_idx = nan(nProd, 1);

% To determine cost at each consumption, replay the weighted-avg logic
% component by component, this time also writing into WIP
inv_qty_tmp = zeros(nComp, 1);
inv_EUR_tmp = zeros(nComp, 1);

% Collect ALL events chronologically (across all components)
allEvents = [];   % [dateIdx, compIdx, type, qty, orderNum]
for cj = 1:nComp
  idxRec = find(dc.s.itemNumber == cj & dc.s.stockTransactionType == 25);
  idxCon = find(dc.s.itemNumber == cj & dc.s.stockTransactionType == 11);
  for k = 1:length(idxRec)
    r = idxRec(k);
    idx = dateIdx(dc.s.entryDate(r));
    if isempty(idx), continue; end
    allEvents(end+1, :) = [idx, cj, 25, dc.s.transactionQuantityBasicUM(r), dc.s.orderNumber(r)];  %#ok<AGROW>
  end
  for k = 1:length(idxCon)
    r = idxCon(k);
    idx = dateIdx(dc.s.entryDate(r));
    if isempty(idx), continue; end
    allEvents(end+1, :) = [idx, cj, 11, -dc.s.transactionQuantityBasicUM(r), dc.s.orderNumber(r)];  %#ok<AGROW>
  end
end
allEvents = sortrows(allEvents, 1);

% Track WIP changes as delta events (per date index), to build time series
wip_delta = zeros(M, 1);   % daily WIP change (positive at consumption, negative at delivery)

for e = 1:size(allEvents, 1)
  idx = allEvents(e, 1);
  cj  = allEvents(e, 2);
  typ = allEvents(e, 3);
  qty = allEvents(e, 4);
  pon = allEvents(e, 5);

  if typ == 25
    % Receipt: add to inventory
    poRow = find(dc.p.purchaseOrderNumber == pon, 1);
    if isempty(poRow), continue; end
    cost_FX = dc.p.lineAmountOrderCurrency(poRow);
    iCur    = dc.p.iCur(poRow);
    if iCur == iCurFunctional
      fxRate = 1;
    else
      fxRate = dm.fx{iCur, iCurFunctional}(idx);
    end
    cost_EUR = cost_FX * fxRate;
    inv_qty_tmp(cj) = inv_qty_tmp(cj) + qty;
    inv_EUR_tmp(cj) = inv_EUR_tmp(cj) + cost_EUR;

  else   % typ == 11: consumption → add to WIP
    if inv_qty_tmp(cj) > 0
      avg_cost = inv_EUR_tmp(cj) / inv_qty_tmp(cj);
    else
      avg_cost = 0;
    end
    cost_removed = qty * avg_cost;
    inv_qty_tmp(cj) = inv_qty_tmp(cj) - qty;
    inv_EUR_tmp(cj) = inv_EUR_tmp(cj) - cost_removed;

    % Add to WIP for this product (pon = productId)
    prodIdx = find(dc.productNumbers == pon, 1);
    if isempty(prodIdx), continue; end
    wip_delta(idx) = wip_delta(idx) + cost_removed;
    wip_per_product(prodIdx) = wip_per_product(prodIdx) + cost_removed;

    % Track when WIP starts for this product
    if isnan(wip_start_idx(prodIdx))
      wip_start_idx(prodIdx) = idx;
    end
  end
end

% Now account for WIP release at delivery: for each product, subtract
% its total WIP value on its delivery date.
%
% The amount released = product's COGS in EUR (historical cost).
% We also track this per day in bs.dI_C so that buildFunctionalPnL uses
% the EXACT same COGS value as the balance sheet (ensures ΔB^N = I^N).
bs.dI_C = zeros(M, 1);
for pIdx = 1:nProd
  dDate = productDeliveryDate(pIdx);
  if isnan(dDate), continue; end
  idx = dateIdx(dDate);
  if isempty(idx), continue; end
  wip_delta(idx) = wip_delta(idx) - wip_per_product(pIdx);
  bs.dI_C(idx)   = bs.dI_C(idx) + wip_per_product(pIdx);
end

bs.B_W = cumsum(wip_delta);

%% ========================================================================
%  Cash (EUR)  —  starts at 0
%  Updates from: AR payments in, AP payments out
%  Note: dividend/sweep to parent is handled separately (not in this bs)
%% ========================================================================

cash_delta = zeros(M, 1);

% AR payments in (at payment date, converted at that day's rate)
payRowsAR = find(dc.a.transactionCode == 20);
for k = 1:length(payRowsAR)
  r    = payRowsAR(k);
  tP   = dc.a.accountingDate(r);
  c    = dc.a.iCur(r);
  amt  = -dc.a.foreignCurrencyAmount(r);   % code 20 stores negative → flip sign to get positive inflow
  idx  = dateIdx(tP);
  if isempty(idx), continue; end
  if c == iCurFunctional
    fxRate = 1;
  else
    fxRate = dm.fx{c, iCurFunctional}(idx);
  end
  cash_delta(idx) = cash_delta(idx) + amt * fxRate;
end

% AP payments out
payRowsAP = find(dc.ap.transactionCode == 20);
for k = 1:length(payRowsAP)
  r   = payRowsAP(k);
  tP  = dc.ap.accountingDate(r);
  c   = dc.ap.iCur(r);
  amt = -dc.ap.foreignCurrencyAmount(r);   % code 20 stores negative → flip to get the payment amount (positive outflow)
  idx = dateIdx(tP);
  if isempty(idx), continue; end
  if c == iCurFunctional
    fxRate = 1;
  else
    fxRate = dm.fx{c, iCurFunctional}(idx);
  end
  cash_delta(idx) = cash_delta(idx) - amt * fxRate;
end

% Dividend / cash sweep to parent (loaded from simulation output).
% These are recorded in createMatFilesSim and saved to dividendEvents.mat.
bs.dividendEUR = zeros(M, 1);
divFile = fullfile('simulatedData', 'dividendEvents.mat');
if isfile(divFile)
  S = load(divFile);
  if isfield(S, 'dividendEvents') && ~isempty(S.dividendEvents)
    for k = 1:size(S.dividendEvents, 1)
      d   = S.dividendEvents(k, 1);
      amt = S.dividendEvents(k, 2);
      idx = dateIdx(d);
      if isempty(idx), continue; end
      cash_delta(idx)     = cash_delta(idx) - amt;   % cash leaves subsidiary
      bs.dividendEUR(idx) = bs.dividendEUR(idx) + amt;
    end
  end
end

bs.B_C = cumsum(cash_delta);

%% ========================================================================
%  Net Assets
%% ========================================================================

bs.B_N = bs.B_I + bs.B_W + bs.AR_EUR - bs.AP_EUR + bs.B_C;

end
