% runPA  Single-run Performance Attribution for the thesis simulation.
%
% Loads market data (once), generates a simulated transaction dataset,
% runs the full PA pipeline, prints PAM FX benchmarks and FX gains.

clear settings;
settings.dataFolder    = 'simulatedData';
settings.bomPricing    = 'DeterministicCashFlows';
settings.curFunctional = 'EUR';
settings.startDate     = datenum(2007,1,1);  % Change to 2005 when FX data is available
settings.endDate       = datenum(2025,12,31);
settings.usedItemNumbersOrg = [];
settings.usedProductNumbers = [];
% Thesis currencies only (Table 4.5 + procurement + functional/presentation)
% Sales: USD AUD CAD GBP ZAR INR CNY
% Procurement: USD EUR CNY GBP
% Functional/Presentation: EUR SEK
% INR dropped due to limited yield curve history (starts Nov 2010)
settings.currencies = {'AUD','CAD','CNY','EUR','GBP','SEK','USD','ZAR'};

marketDataSet = 'reutersZero';

if (~exist('dm', 'var'))
  [dm] = createDataMarket(marketDataSet, settings);
end

createMatFilesSim(dm, 1, true);

[dc] = createDataCompany(dm, settings);
[dp] = buildPA(dm, dc);
[dr] = performanceAttribution(dm, dc, dp);

% -------------------------------------------------------------------------
% Method 2 — Industry accounting method with sub-period average rates
%  Three variants: weekly, monthly, quarterly averaging windows.
%  Same shared core (EUR P&L + balance sheet); only the
%  translation step differs (daily rate → sub-period avg rate).
% -------------------------------------------------------------------------
addpath(fullfile('IndustryMethods','Method2'));
m2 = computeMethod2(dm, dc);

fprintf('\n=== Method 2: FX Impacts per Quarter (SEK) — all 3 averaging windows ===\n');
fprintf('%-12s %14s %14s %14s %14s %14s %14s\n', 'Period end', ...
  'TI (weekly)', 'OCI (weekly)', 'TI (monthly)', 'OCI (monthly)', ...
  'TI (quarterly)', 'OCI (quarterly)');
fprintf('%s\n', repmat('-', 1, 102));
for p = 1:length(m2.periodEndDates)
  haveAny = m2.weekly.TI(p) ~= 0 || m2.weekly.OCI(p) ~= 0 || ...
            m2.monthly.TI(p) ~= 0 || m2.monthly.OCI(p) ~= 0 || ...
            m2.quarterly.TI(p) ~= 0 || m2.quarterly.OCI(p) ~= 0;
  if ~haveAny, continue; end
  fprintf('%-12s %14s %14s %14s %14s %14s %14s\n', ...
    datestr(m2.periodEndDates(p), 'yyyy-mm-dd'), ...
    fmtNum(m2.weekly.TI(p)),    fmtNum(m2.weekly.OCI(p)), ...
    fmtNum(m2.monthly.TI(p)),   fmtNum(m2.monthly.OCI(p)), ...
    fmtNum(m2.quarterly.TI(p)), fmtNum(m2.quarterly.OCI(p)));
end
fprintf('%s\n', repmat('-', 1, 102));
fprintf('%-12s %14s %14s %14s %14s %14s %14s\n', 'TOTAL', ...
  fmtNum(sum(m2.weekly.TI)),    fmtNum(sum(m2.weekly.OCI)), ...
  fmtNum(sum(m2.monthly.TI)),   fmtNum(sum(m2.monthly.OCI)), ...
  fmtNum(sum(m2.quarterly.TI)), fmtNum(sum(m2.quarterly.OCI)));

fprintf('\nFinal portfolio value (SEK): %s\n', fmtNum(dr.V(end), 4));
