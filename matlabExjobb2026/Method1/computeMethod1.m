function [m1] = computeMethod1(dm, dc, periodDates)
% computeMethod1  FX result under Method 1 (Actual Rate) per period.
%
%   m1 = computeMethod1(dm, dc)
%   m1 = computeMethod1(dm, dc, periodDates)
%
% Method 1 — Actual Rate (thesis Section 4.2.2):
%   Each revenue/cost item is translated at the spot exchange rate on the
%   transaction date.  AR and AP balances are remeasured at the period-end
%   closing rate each period.
%
%   FX gain on AR settled in period p  (Eq. 4.13 with actual rates):
%     A_j * (e_{settlement} - e_{reference})
%
%   FX gain on AR outstanding at period end (Eq. 4.14):
%     A_j * (e_{T_p} - e_{reference})
%
%   FX gain on AP settled in period p  (Eq. 4.15):
%     -C_{j,l} * (e_{payment} - e_{reference})
%
%   FX gain on AP outstanding at period end (Eq. 4.16):
%     -C_{j,l} * (e_{T_p} - e_{reference})
%
%   Reference rate t^ref:
%     = transaction date  if first recognised in current period
%     = previous period-end closing rate  if carried over
%
% All values in EUR (functional currency).
%
% Output fields:
%   m1.AR_real(p)    AR realised FX gain in period p
%   m1.AR_unreal(p)  AR unrealised FX gain at end of period p
%   m1.AP_real(p)    AP realised FX gain in period p
%   m1.AP_unreal(p)  AP unrealised FX gain at end of period p
%   m1.AR_total(p)   AR_real + AR_unreal
%   m1.AP_total(p)   AP_real + AP_unreal
%   m1.total(p)      AR_total + AP_total  (Eq. 4.17)
%   m1.periodDates   period boundary dates used

% =========================================================================
% Period dates
% =========================================================================
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));  % parent folder for makeQuarterDates
if nargin < 3 || isempty(periodDates)
  periodDates = makeQuarterDates(dm.dates(1), dm.dates(end));
end

% =========================================================================
% Delegate to the shared FX gain computation
% (Method 1 uses actual spot rates — identical to what computeFXGains does)
% =========================================================================
m1 = computeFXGains(dm, dc, periodDates);

end
