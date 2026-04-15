% runPA  Single-run Performance Attribution for the thesis simulation.
%
% Loads market data (once), generates a simulated transaction dataset,
% runs the full PA pipeline, prints PAM FX benchmarks and FX gains.

clear settings;
settings.dataFolder    = 'simulatedData';
settings.bomPricing    = 'StochasticPrices';
settings.curFunctional = 'EUR';
settings.startDate     = datenum(2007,1,1);  % Change to 2005 when FX data is available
settings.endDate       = datenum(2025,12,31);
settings.usedItemNumbersOrg = [];
settings.usedProductNumbers = [];
% Thesis currencies only (Table 4.5 + procurement + functional/presentation)
% Sales: USD AUD CAD GBP ZAR INR CNY
% Procurement: USD EUR CNY GBP
% Functional/Presentation: EUR SEK
settings.currencies = {'AUD','CAD','CNY','EUR','GBP','INR','SEK','USD','ZAR'};

marketDataSet = 'reutersZero';

if (~exist('dm', 'var'))
  [dm] = createDataMarket(marketDataSet, settings);
end

createMatFilesSim(dm, 1, true);

[dc] = createDataCompany(dm, settings);
[dp] = buildPA(dm, dc);
[dr] = performanceAttribution(dm, dc, dp);

% -------------------------------------------------------------------------
% Realized / unrealized FX gains on AR and AP — Method 1 (thesis Eqs. 4.13-4.17)
% -------------------------------------------------------------------------
addpath('Method1');
[fxg] = computeMethod1(dm, dc);

fprintf('\n=== FX Gains per Quarter (EUR functional currency) ===\n');
fprintf('%-12s %12s %12s %12s %12s %12s\n', ...
  'Period end', 'AR real', 'AR unreal', 'AP real', 'AP unreal', 'Total');
fprintf('%s\n', repmat('-',1,74));
for p = 1:length(fxg.periodDates)-1
  if fxg.AR_total(p)==0 && fxg.AP_total(p)==0, continue; end
  fprintf('%-12s %12.0f %12.0f %12.0f %12.0f %12.0f\n', ...
    datestr(fxg.periodDates(p+1),'yyyy-mm-dd'), ...
    fxg.AR_real(p), fxg.AR_unreal(p), ...
    fxg.AP_real(p), fxg.AP_unreal(p), fxg.total(p));
end
fprintf('%s\n', repmat('-',1,74));
fprintf('%-12s %12.0f %12.0f %12.0f %12.0f %12.0f\n', 'TOTAL', ...
  sum(fxg.AR_real), sum(fxg.AR_unreal), ...
  sum(fxg.AP_real), sum(fxg.AP_unreal), sum(fxg.total));

fprintf('\nFinal portfolio value (SEK): %.4f\n', dr.V(end));
