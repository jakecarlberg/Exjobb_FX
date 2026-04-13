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
  settings.dataFolder = 'simulatedData';
  settings.bomPricing = 'StochasticPrices';

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



if (testCase == 1)
  fprintf('Final value LastProcurementPrice = %.10f\n', 57587.9972338254);
  fprintf('Final value InternalPrice        = %.10f\n', 64575.8621360606);
end

fprintf('Final value current              = %.10f\n', dr.V(end));
