function mv = translateMethod2(dm, pnl, bs, subPeriodType)
% translateMethod2  Method 2 translation using sub-period average rates.
%
%   mv = translateMethod2(dm, pnl, bs, 'week' | 'month' | 'quarter')
%
% For each sub-period s contained in quarter p:
%   - Accumulate daily EUR increments of I^R, I^C, I^F within s
%   - On the last day of s, translate the accumulated EUR at the arithmetic
%     mean of f_{EUR,SEK} over s, and add to the quarterly SEK accumulator
%
% Sub-periods are truncated at quarter boundaries (a calendar week spanning
% two quarters is split into two separate sub-periods, each with its own
% average rate).
%
% Outputs (per quarter):
%   mv.TI   [Q x 1]  - Transactional Impact in SEK (eq 4.21)
%   mv.OCI  [Q x 1]  - Translation Impact (OCI) in SEK (eq 4.22-4.25)
%
% Debug fields:
%   mv.subPeriodType, mv.I_R_SEK_q, mv.I_C_SEK_q, mv.I_F_SEK_q, mv.I_N_SEK_q
%   mv.dayAvgRate  [M x 1]  - sub-period avg EUR/SEK rate per day
%   mv.subId       [M x 1]  - unique sub-period identifier per day

M = length(dm.dates);
iCurFunctional   = find(ismember(dm.cName, 'EUR'));
iCurPresentation = find(ismember(dm.cName, 'SEK'));

f_EUR_SEK = dm.fx{iCurFunctional, iCurPresentation};

% --- Sub-period identifiers per day ---------------------------------------
% We combine calendar-unit ID with quarter ID so that any sub-period that
% would straddle a quarter boundary is automatically split into two.

[Y, Mo, ~] = datevec(dm.dates);
Y = Y(:);  Mo = Mo(:);
Q = floor((Mo - 1) / 3) + 1;                         % 1..4

switch lower(subPeriodType)
  case 'week'
    % Monday-start weeks using Jan 5 1970 (a Monday) as the global reference.
    refMon = datenum(1970, 1, 5);
    weekIdx = floor((dm.dates(:) - refMon) / 7);     % unique integer per ISO-like week
    subId = weekIdx * 10 + Q;                         % split at quarter boundary
  case 'month'
    subId = Y * 100 + Mo;                             % calendar month (month boundary = Q boundary when applicable)
  case 'quarter'
    subId = Y * 10 + Q;                               % full calendar quarter
  otherwise
    error('subPeriodType must be ''week'', ''month'', or ''quarter''.');
end

% --- Sub-period average EUR/SEK rate (arithmetic mean of daily rates) -----

dayAvgRate = zeros(M, 1);
uniqSub = unique(subId);
for u = 1:length(uniqSub)
  mask = (subId == uniqSub(u));
  dayAvgRate(mask) = mean(f_EUR_SEK(mask));
end

% --- Daily SEK increments translated at sub-period average rate -----------
% (Equivalent to the thesis formulation where the sub-period EUR sum is
%  translated once at the last day of the sub-period: quarter-end totals
%  match exactly; intermediate daily values differ but don't affect TI/OCI.)

dI_R_SEK = pnl.dI_R .* dayAvgRate;
dI_C_SEK = pnl.dI_C .* dayAvgRate;
dI_F_SEK = pnl.dI_F .* dayAvgRate;
dI_N_SEK = dI_R_SEK - dI_C_SEK + dI_F_SEK;

% --- Aggregate over each reporting quarter --------------------------------

qStart = pnl.quarterStartIdx;
qEnd   = pnl.quarterEndIdx;
Qn     = length(qEnd);

I_R_SEK_q = zeros(Qn, 1);
I_C_SEK_q = zeros(Qn, 1);
I_F_SEK_q = zeros(Qn, 1);
I_N_SEK_q = zeros(Qn, 1);

for q = 1:Qn
  rng = qStart(q):qEnd(q);
  I_R_SEK_q(q) = sum(dI_R_SEK(rng));
  I_C_SEK_q(q) = sum(dI_C_SEK(rng));
  I_F_SEK_q(q) = sum(dI_F_SEK(rng));
  I_N_SEK_q(q) = sum(dI_N_SEK(rng));
end

% --- Transactional Impact (eq 4.21) ---------------------------------------

mv.TI = I_F_SEK_q;

% --- Translation Impact / OCI (eq 4.22-4.25) ------------------------------
% B^N is method-independent; only I^N_SEK differs between methods.

OCI = zeros(Qn, 1);
for q = 1:Qn
  tStart = qStart(q);
  tEnd   = qEnd(q);

  if q == 1
    BN_open_SEK = 0;
  else
    tPrevEnd    = qEnd(q - 1);
    BN_open_SEK = bs.B_N(tPrevEnd) * f_EUR_SEK(tPrevEnd);
  end
  BN_close_SEK = bs.B_N(tEnd) * f_EUR_SEK(tEnd);

  % Dividends paid during quarter (translated at sweep-day rate, same as M1)
  divInQuarter = sum(bs.dividendEUR(tStart:tEnd) .* f_EUR_SEK(tStart:tEnd));

  BE_SEK = BN_open_SEK + I_N_SEK_q(q) - divInQuarter;
  OCI(q) = BN_close_SEK - BE_SEK;
end

mv.OCI = OCI;

% --- Debug / inspection fields --------------------------------------------

mv.subPeriodType = subPeriodType;
mv.I_R_SEK_q     = I_R_SEK_q;
mv.I_C_SEK_q     = I_C_SEK_q;
mv.I_F_SEK_q     = I_F_SEK_q;
mv.I_N_SEK_q     = I_N_SEK_q;
mv.dayAvgRate    = dayAvgRate;
mv.subId         = subId;

end
