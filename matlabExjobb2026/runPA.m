testCase = 3;

clear settings;
% if settings.usedProductNumber is not defined, then all are removed, and if empty vector, then all are used
if (testCase == 0)
  settings.dataFolder = 'epiroc2021';
  settings.bomPricing = 'DeterministicCashFlows';

  % If usedItemNumbersOrg is not created, then no products will be used
%   settings.usedItemNumbersOrg = [];
%   settings.usedItemNumbersOrg = [3222344319];
  

  % If usedProductNumbers is not created, then no products will be used
  settings.usedProductNumbers = [];
  marketDataSet = 'epiroc2021';
  settings.startDate = datenum(2020,09,14);
  settings.endDate = datenum(2021,02,18);
  
elseif (testCase == 1)
  settings.dataFolder = 'epiroc2023';
  settings.bomPricing = 'DeterministicCashFlows';

  % If usedItemNumbersOrg is not created, then no products will be used
%   settings.usedItemNumbersOrg = [];
%   settings.usedItemNumbersOrg = [3222344319];
  

  % If usedProductNumbers is not created, then no products will be used
  settings.usedProductNumbers = [8992014203];

  marketDataSet = 'reutersZero';
elseif (testCase == 2)
  settings.dataFolder = 'epiroc2024';
  settings.bomPricing = 'StochasticPrices';

  % settings.usedItemNumbersOrg = [];
  settings.usedItemNumbersOrg = [3222344319];
  %settings.usedItemNumbersOrg = [4350276102];
  %settings.usedItemNumbersOrg = [3222364616];

  % If usedProductNumbers is not created, then no products will be used
  settings.usedProductNumbers = [8992014203]; % Use only these products

  marketDataSet = 'reutersZero';
elseif (testCase == 3)
  settings.dataFolder    = 'simulatedData';
  settings.bomPricing    = 'StochasticPrices';
  settings.curFunctional = 'EUR';              % Thesis Section 4.3.1
  settings.startDate     = datenum(2005,1,1);  % Thesis Section 4.2.1: January 2005
  settings.endDate       = datenum(2025,12,31);% Thesis Section 4.2.1: December 2025

  settings.usedItemNumbersOrg = [];
%   settings.usedItemNumbersOrg = [1];

  % If usedProductNumbers is not created, then no products will be used
  settings.usedProductNumbers = []; % Use all products
%   settings.usedProductNumbers = [1]; % Use only these products

  marketDataSet = 'reutersZero';
end

if (~isfield(settings, 'usedItemNumbersOrg') && ~isfield(settings, 'usedProductNumbers'))
  error('At least one of the fields (usedItemNumbersOrg, usedProductNumbers) has to be set in settings');
end

if (~exist('dm', 'var')) % Only load data once (improves speed)
  [dm] = createDataMarket(marketDataSet, settings);
end
[dc] = createDataCompany(dm, settings);
[dp] = buildPA(dm, dc);
[dr] = performanceAttribution(dm, dc, dp);

% -------------------------------------------------------------------------
% Realized / unrealized FX gains on AR and AP (thesis Eqs. 4.13-4.17)
% -------------------------------------------------------------------------
[fxg] = computeFXGains(dm, dc);

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

if (testCase == 1)
  fprintf('Final value LastProcurementPrice = %.10f\n', 57587.9972338254);
  fprintf('Final value InternalPrice        = %.10f\n', 64575.8621360606);
end

fprintf('\nFinal portfolio value (SEK): %.4f\n', dr.V(end));
