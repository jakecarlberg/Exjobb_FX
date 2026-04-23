function pnl = buildFunctionalPnL(dm, dc, bs)
% buildFunctionalPnL  Build daily P&L accumulators in EUR (functional currency).
%
%   pnl = buildFunctionalPnL(dm, dc, bs)
%
% Produces daily time series of P&L accumulators, which RESET at the start of
% each quarter (first trading day of Jan, Apr, Jul, Oct). The quarter-end
% values are the reported P&L figures.
%
% Outputs:
%   pnl.dates        [M x 1]
%   pnl.I_R          [M x 1]   - Revenue (eq 4.3)
%   pnl.I_C          [M x 1]   - COGS (eq 4.4)
%   pnl.I_FU         [M x 1]   - Unrealized FX gain/loss (eq 4.7)
%   pnl.I_FR         [M x 1]   - Realized FX gain/loss (eq 4.8)
%   pnl.I_F          [M x 1]   - Total FX = I_FU + I_FR
%   pnl.I_N          [M x 1]   - Net income = I_R - I_C + I_F
%   pnl.dI_R, dI_C, dI_FU, dI_FR, dI_F, dI_N  - daily increments (no reset)
%   pnl.quarterEndIdx  [Q x 1] - indices of last trading day in each quarter
%   pnl.quarterStartIdx[Q x 1] - indices of first trading day in each quarter

M = length(dm.dates);
iCurFunctional = find(ismember(dm.cName, 'EUR'));
nCur = length(dm.cName);

pnl.dates = dm.dates;

% Quarter markers (start index and end index of each quarter present in dm.dates)
[Y, Mo, ~] = datevec(dm.dates);
quarterOfDate = floor((Mo - 1) / 3) + 1;     % 1..4
qKey = Y(:) * 10 + quarterOfDate(:);         % force column
qChange = [1; find(diff(qKey) ~= 0) + 1];    % indices where a new quarter starts
pnl.quarterStartIdx = qChange;
pnl.quarterEndIdx   = [qChange(2:end) - 1; M];

%% ========================================================================
%  Daily INCREMENTS (before quarter-reset accumulation)
%% ========================================================================

dI_R  = zeros(M, 1);
dI_C  = zeros(M, 1);
dI_FU = zeros(M, 1);
dI_FR = zeros(M, 1);

dateIdx = @(d) find(dm.dates >= d, 1, 'first');

% ----- Revenue increments (eq 4.3): at delivery date, in EUR at that day's rate
invRowsAR = find(dc.a.transactionCode == 10);
for k = 1:length(invRowsAR)
  r   = invRowsAR(k);
  tD  = dc.a.accountingDate(r);
  c   = dc.a.iCur(r);
  C   = dc.a.foreignCurrencyAmount(r);
  idx = dateIdx(tD);
  if isempty(idx), continue; end
  if c == iCurFunctional
    fxRate = 1;
  else
    fxRate = dm.fx{c, iCurFunctional}(idx);
  end
  dI_R(idx) = dI_R(idx) + C * fxRate;
end

% ----- COGS increments (eq 4.4): at delivery date, WIP released for that product
% Use bs.dI_C (computed in buildBalanceSheet as the actual WIP value released
% on each day). This ensures the accounting identity ΔB^N = I^N holds, because
% COGS and WIP release use exactly the same EUR value.
dI_C = bs.dI_C;

% ----- Unrealized FX increments (eq 4.7)
% Daily revaluation: (AR_face(t-1) - AP_face(t-1)) * (f_t - f_{t-1})
% Plus reclassification at settlement (moves cumulative unrealized into realized)
for t = 2:M
  for c = 1:nCur
    if c == iCurFunctional, continue; end
    fx_t   = dm.fx{c, iCurFunctional}(t);
    fx_tm1 = dm.fx{c, iCurFunctional}(t-1);
    if isnan(fx_t) || isnan(fx_tm1), continue; end
    exposure = bs.AR_face(t-1, c) - bs.AP_face(t-1, c);
    dI_FU(t) = dI_FU(t) + exposure * (fx_t - fx_tm1);
  end
end

% Reclassification at AR settlement (unrealized → realized): subtract cum gain from I_FU
payRowsAR = find(dc.a.transactionCode == 20);
for k = 1:length(payRowsAR)
  r   = payRowsAR(k);
  invNum = dc.a.invoiceNumber(r);
  c      = dc.a.iCur(r);
  if c == iCurFunctional, continue; end
  tP     = dc.a.accountingDate(r);
  idxP   = dateIdx(tP);
  if isempty(idxP), continue; end
  % Find matching code 10 (delivery)
  r1 = find(dc.a.transactionCode == 10 & dc.a.invoiceNumber == invNum, 1);
  if isempty(r1), continue; end
  tD   = dc.a.accountingDate(r1);
  idxD = dateIdx(tD);
  if isempty(idxD), continue; end
  C    = dc.a.foreignCurrencyAmount(r1);
  fx_P = dm.fx{c, iCurFunctional}(idxP);
  fx_D = dm.fx{c, iCurFunctional}(idxD);
  cumGain = C * (fx_P - fx_D);
  dI_FU(idxP) = dI_FU(idxP) - cumGain;
  dI_FR(idxP) = dI_FR(idxP) + cumGain;
end

% Reclassification at AP settlement (note sign convention - opposite of AR)
payRowsAP = find(dc.ap.transactionCode == 20);
for k = 1:length(payRowsAP)
  r   = payRowsAP(k);
  apNum  = dc.ap.invoiceNumber(r);
  c      = dc.ap.iCur(r);
  if c == iCurFunctional, continue; end
  tP     = dc.ap.accountingDate(r);
  idxP   = dateIdx(tP);
  if isempty(idxP), continue; end
  r1 = find(dc.ap.transactionCode == 10 & dc.ap.invoiceNumber == apNum, 1);
  if isempty(r1), continue; end
  tD   = dc.ap.accountingDate(r1);
  idxD = dateIdx(tD);
  if isempty(idxD), continue; end
  C    = dc.ap.foreignCurrencyAmount(r1);
  fx_P = dm.fx{c, iCurFunctional}(idxP);
  fx_D = dm.fx{c, iCurFunctional}(idxD);
  cumGain = C * (fx_P - fx_D);
  % AP: opposite sign to AR (see eq 4.7 vs 4.8)
  dI_FU(idxP) = dI_FU(idxP) + cumGain;
  dI_FR(idxP) = dI_FR(idxP) - cumGain;
end

dI_F = dI_FU + dI_FR;
dI_N = dI_R - dI_C + dI_F;

%% ========================================================================
%  Quarterly-resetting accumulators (cumsum within each quarter)
%% ========================================================================

I_R  = accumulateByQuarter(dI_R,  pnl.quarterStartIdx);
I_C  = accumulateByQuarter(dI_C,  pnl.quarterStartIdx);
I_FU = accumulateByQuarter(dI_FU, pnl.quarterStartIdx);
I_FR = accumulateByQuarter(dI_FR, pnl.quarterStartIdx);
I_F  = I_FU + I_FR;
I_N  = I_R - I_C + I_F;

pnl.I_R  = I_R;
pnl.I_C  = I_C;
pnl.I_FU = I_FU;
pnl.I_FR = I_FR;
pnl.I_F  = I_F;
pnl.I_N  = I_N;

% Daily increments (useful for Method 1 translation)
pnl.dI_R  = dI_R;
pnl.dI_C  = dI_C;
pnl.dI_FU = dI_FU;
pnl.dI_FR = dI_FR;
pnl.dI_F  = dI_F;
pnl.dI_N  = dI_N;

end


%% ========================================================================
%  Helper: cumsum that resets at each quarter boundary
%% ========================================================================
function out = accumulateByQuarter(x, qStartIdx)
  out = zeros(size(x));
  nQ = length(qStartIdx);
  for q = 1:nQ
    a = qStartIdx(q);
    if q < nQ, b = qStartIdx(q+1) - 1; else, b = length(x); end
    out(a:b) = cumsum(x(a:b));
  end
end
