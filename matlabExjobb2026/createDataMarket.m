function [dm] = createDataMarket(marketDataSet, settings)
% Create Data Market structure, dm, with interest rates and exchange rates for each currency

% Currencies procurement: AUD, CAD, CHF, EUR, GBP, INR, JPY, NOK, SEK, ZAR
% Currencies sales (additional): BGN, BWP, CLP, CNY, CZK, HKD, KRW, MXN, PEN, PLN, RUB, SGD, THB
% Joint: AUD=;BGN=;BWP=;CAD=;CHF=;CLP=;CNY=;CZK=;EUR=;GBP=;HKD=;INR=;JPY=;KRW=;MXN=;NOK=;PEN=;PLN=;RUB=;SEK=;SGD=;THB=;ZAR=

% startDate = datenum(1900,1,1); % Start as early as possible
startDate = datenum(2020,9,14); % 
endDate = datenum(2100,1,1); % End as late as possible
% startDate = datenum(2023,4,5); 
% endDate = datenum(2023,4,6); 
dm.dt = 1/365; % Use daily discretization in interest rate curves

if (isfield(settings, 'startDate'))
  startDate = settings.startDate;
end
if (isfield(settings, 'endDate'))
  endDate = settings.endDate;
end

if (strcmp(marketDataSet, 'reutersZero')) % Interest rates based on Reuters zero-coupon curves
%   currencies = {'AUD', 'BGN', 'BWP', 'CAD', 'CHF', 'CLP', 'CNY', 'CZK', 'EUR', 'GBP', 'HKD', 'INR', 'JPY', 'KRW', 'MXN', 'NOK', 'PEN', 'PLN', 'RUB', 'SEK', 'SGD', 'THB', 'USD', 'ZAR'};
  invertedCurrencies = {'AUD', 'BWP', 'EUR', 'FJD', 'FKP', 'GBP', 'GIP', 'NZD', 'PGK', 'SBD', 'SHP', 'TOP', 'WST', 'XAG', 'XAU', 'XPD', 'XPT'};

  fileName = ['marketData\fx.xlsx'];
  d = readtable(fileName);
  dates = datenum(d{:,1});

  % Read all currencies from file, then filter to settings.currencies if provided
  allCurrencies = {'USD'};
  for i=2:size(d,2)
    str = char(d.Properties.VariableNames{i});
    allCurrencies{end+1} = str(1:3); %#ok<AGROW>
  end

  if isfield(settings, 'currencies')
    % Keep only the requested currencies (always include USD for cross-rate computation)
    keepSet = union(settings.currencies, {'USD'});
    allCurrencies = allCurrencies(ismember(allCurrencies, keepSet));
  end

  currencies = sort(allCurrencies(:));
  nc = length(currencies);
  dm.cName = currencies;
  kUSD = find(ismember(dm.cName, 'USD'));
  cOrg = cell(nc,1);
  fxOrg = cell(nc, nc);
  for i=1:nc
    if (strcmp(char(currencies{i}), 'USD'))
      continue;
    elseif (~isempty(find(ismember(invertedCurrencies, currencies{i}))))
      iBase = i;
      iTerm = kUSD;
    else
      iBase = kUSD;
      iTerm = i;
    end
    colName = [currencies{i} '_'];
    fxRates = d{:, colName};
    ind = find(~isnan(fxRates));
    fxOrg{iBase, iTerm}.f = fxRates(ind(end:-1:1));
    fxOrg{iBase, iTerm}.dates = dates(ind(end:-1:1));
  end

  for i=1:nc
    fileName = ['marketData\' char(currencies{i}) '100.mat'];
    if isfile(fileName)
      d = load(fileName);
    else
      fprintf('Missing interest rate data for currency %s\n', currencies{i});
      fileName = ['marketData\USD100.mat'];
      d = load(fileName);
      d.fH = zeros(size(d.fH));
    end
    cOrg{i}.fH = d.fH; cOrg{i}.firstDates = d.firstDates; cOrg{i}.lastDates = d.lastDates; cOrg{i}.dates = d.dates;
  end

elseif (strcmp(marketDataSet, 'epiroc2021')) % Based on multiple yield curves
  fileNames = {'AUDUSD10', 'EURUSD100', 'GBPUSD10', 'USDNOK10', 'USDSEK10'};


  cHome = 'SEK'; % Home currency
  nFiles = length(fileNames);
  cBase = cell(nFiles,1);
  cTerm = cell(nFiles,1);

  for i=1:nFiles
    cBase{i} = fileNames{i}(1:3);
    cTerm{i} = fileNames{i}(4:6);
  end

  dm.cName = unique([cBase ; cTerm]);

  nc = length(dm.cName);

  if (nFiles+1 ~=nc)
    error('Each currency should only be present in one exchange rate');
  end

  % Store exchange rates and interest rate curves
  % Note that pi-curves are added to interest rate curves, for pricing to be consistent with fx-swaps - it creates higher volatilities in interest rate curves...

  cOrg = cell(nc,1);
  fxOrg = cell(nc, nc);

  iHome = find(ismember(cTerm, cHome)); 

  d = load(fileNames{iHome});

  kHome = find(ismember(dm.cName, cHome));
  cOrg{kHome}.fH = d.fTermH; cOrg{kHome}.firstDates = d.firstDates; cOrg{kHome}.lastDates = d.lastDates; cOrg{kHome}.dates = floor(d.times);

  kUSD = find(ismember(dm.cName, 'USD'));
  cOrg{kUSD}.fH = d.fBaseH + d.piH; cOrg{kUSD}.firstDates = d.firstDates; cOrg{kUSD}.lastDates = d.lastDates; cOrg{kUSD}.dates = floor(d.times);

  fxOrg{kUSD, kHome}.f = d.exchangeRateH;
  fxOrg{kUSD, kHome}.dates = floor(d.times);

  for i=1:nFiles
    if (i == kHome)
      continue; % Already stored values
    end
    d = load(fileNames{i});
    iBase = find(ismember(dm.cName, cBase{i}));
    iTerm = find(ismember(dm.cName, cTerm{i}));
    if (iBase == kUSD)
      cOrg{iTerm}.fH = d.fTermH - d.piH; cOrg{iTerm}.firstDates = d.firstDates; cOrg{iTerm}.lastDates = d.lastDates; cOrg{iTerm}.dates = floor(d.times);
    elseif (iTerm == kUSD) % Inverted exchange rate
      cOrg{iBase}.fH = d.fBaseH + d.piH; cOrg{iBase}.firstDates = d.firstDates; cOrg{iBase}.lastDates = d.lastDates; cOrg{iBase}.dates = floor(d.times);
    else
      error('All exchange rates should include USD');
    end
    fxOrg{iBase, iTerm}.f = d.exchangeRateH;
    fxOrg{iBase, iTerm}.dates = floor(d.times);
  end
else
  error('marketDataSet not defined');  
end

% Check that Saturdays and Sundays are not present in interest rate curves

for k=1:nc
  wd = weekday(cOrg{k}.dates);
  ind = ((wd <= 1) | (wd >= 7));
  if (sum(ind)>=1)
    fprintf('%s: Saturdays or Sundays present in interest rate curves\n', dm.cName{k});    
    error('Exiting')
  end
end

% Remove Saturdays and Sundays from exchange rates

for ki=1:nc
  for kj=1:nc
    if (~isempty(fxOrg{ki,kj}))
      wd = weekday(fxOrg{ki,kj}.dates);
      ind = ((wd >= 2) & (wd <= 6)); % Keep Monday to Friday
      fxOrg{ki,kj}.f = fxOrg{ki,kj}.f(ind); 
      fxOrg{ki,kj}.dates = fxOrg{ki,kj}.dates(ind);
    end
  end
end


% Extrapolate (extend) interest rate curves to cover the same number of maturity dates

nD = max(cOrg{1}.lastDates-cOrg{1}.firstDates);
for k=2:nc
  nD = max(nD, max(cOrg{k}.lastDates-cOrg{k}.firstDates));
end

for k=1:nc
  % Extrapolate interest rate curves (deals with issue that length varies due to holidays and weekends) - required for performance attribution
  nStartExtrapolate = min(cOrg{k}.lastDates-cOrg{k}.firstDates)+1;
  for j = nStartExtrapolate:nD
    ind = (cOrg{k}.lastDates-cOrg{k}.firstDates < j);
    cOrg{k}.fH(ind, j) = cOrg{k}.fH(ind, j-1);
  end
  cOrg{k}.lastDates = cOrg{k}.firstDates + nD;
end

% Compute eigenvectors

dm.e = cell(nc,1);
dm.E = cell(nc,1);

for k=1:nc
  nEigs = 6;
  r = cOrg{k}.fH(2:end,1:nD)-cOrg{k}.fH(1:end-1,1:nD);
  r = r - repmat(mean(r, 1), size(r,1), 1);
  C = cov(r);
  [V,D] = eigs(C, nEigs);
  [dm.e{k},ind] = sort(diag(D),1, 'descend');
  dm.E{k} = V(:,ind);
  ce = cumsum(dm.e{k});
  fTotVar = sum(diag(C));

%   figure(k)
%   ET = (1:nD)'/365;
%   plot(ET, dm.E{k}(:,1), 'b', ET, dm.E{k}(:,2), 'g', ET, dm.E{k}(:,3), 'r');
%   title(['PCA forward rates ' dm.cName{k}])
%   shift     = sprintf('Shift        %5.2f%% (%5.2f%%)\n',100*dm.e{k}(1)/fTotVar, 100*ce(1)/fTotVar);
%   twist     = sprintf('Twist        %5.2f%% (%5.2f%%)\n',100*dm.e{k}(2)/fTotVar, 100*ce(2)/fTotVar);
%   butterfly = sprintf('Butterfly    %5.2f%% (%5.2f%%)\n',100*dm.e{k}(3)/fTotVar, 100*ce(3)/fTotVar);
%   legend(shift,twist,butterfly, 'Location', 'Best');
end


% Fill in values for missing dates in time series (copy values from previous dates)

fDate = startDate;
lDate = endDate;
for k=1:nc
  fDate = max(fDate, cOrg{k}.dates(1));
  lDate = min(lDate, cOrg{k}.dates(end));
end
wd = weekday(fDate:lDate);
usedDate = ((wd >= 2) & (wd <= 6)); % Keep Mo-Fr

% usedDate = false(lDate-fDate+1,1);
% for k=1:nc % Determine dates with at least one value (US holidays remain)
%   ind = (cOrg{k}.dates >= fDate) & (cOrg{k}.dates <= lDate);
%   tmpDates = cOrg{k}.dates(ind);
%   usedDate(tmpDates-fDate+1) = true;
% end
dm.dates = fDate+find(usedDate)-1;

nh = sum(usedDate); % Number of historical dates

dm.fH = cell(nc,1); % Forward rates
for k=1:nc
  dm.fH{k} = ones(nh, nD)*NaN;
  ind = find(cOrg{k}.dates <= fDate);
  ii = ind(end);
  for i=1:nh
    if (ii < length(cOrg{k}.dates))
      if (cOrg{k}.dates(ii+1) == dm.dates(i))
        ii = ii+1;
      else
        fprintf('%s: Copying interest rate curve to date %s\n', dm.cName{k}, datestr(dm.dates(i)));
      end
    end
    dm.fH{k}(i,:) = cOrg{k}.fH(ii,1:nD);
  end
end

dm.fx = cell(nc,nc); % Exchange rates
for ki=1:nc
  for kj=1:nc
    if (~isempty(fxOrg{ki,kj}))
      dm.fx{ki,kj} = ones(nh, 1)*NaN;
      ind = find(fxOrg{ki,kj}.dates <= fDate);
      ii = ind(end);
      for i=1:nh
        if (ii < length(fxOrg{ki,kj}.dates))
          if (fxOrg{ki,kj}.dates(ii+1) == dm.dates(i))
            ii = ii+1;
          else
            fprintf('%s%s: Copying fx-rate to date %s\n', dm.cName{ki}, dm.cName{kj}, datestr(dm.dates(i)));
          end
        end
        dm.fx{ki,kj}(i) = fxOrg{ki,kj}.f(ii);
      end
    end
  end
end

% Compute cross rates

% Phase 1: Invert USD related fx-rates
for k=1:nc
  if (k ~= kUSD)
    if (~isempty(dm.fx{k, kUSD}))
      dm.fx{kUSD, k} = 1./dm.fx{k, kUSD};
    elseif (~isempty(dm.fx{kUSD, k}))
      dm.fx{k, kUSD} = 1./dm.fx{kUSD, k};
    else
      error('Missing interest rate with USD')
    end
  end
end

% Phase 2: Compute all cross rates via USD 

for ki=1:nc
  if (ki == kUSD)
    continue;
  end
  for kj=1:nc
    if (kj == kUSD || ki == kj || ~isempty(dm.fx{ki, kj}))
      continue;
    end
    dm.fx{ki, kj} = dm.fx{ki, kUSD} .* dm.fx{kUSD, kj};
  end
end

% Phase 3: Put ones on diagonal

for k=1:nc
  dm.fx{k, k} = ones(nh,1);
end

% Determine principal components

dm.xiPC = cell(nc,1); % Principal components
for k=1:nc
  dm.xiPC{k} = dm.fH{k} * dm.E{k};
end

% Compute discount factors

dm.d = cell(nc,1); % Discount factors, add column with ones for current date
for k=1:nc
  dm.d{k} = [ones(size(dm.fH{k},1), 1) exp(-cumsum(dm.fH{k},2)*dm.dt)];
end

% Compute minus integral of eigenvectors - used when computing derivatives

dm.negIntE = cell(nc,1); % Negative integral of E, add column with ones for current date
for k=1:nc
  dm.negIntE{k} = [zeros(1, size(dm.E{k},2)) ; -cumsum(dm.E{k},1)*dm.dt];
end


% Create xi matrices

dm.xif = zeros(nh, nc*nc);

j = 1;
for ki=1:nc
  for kj=1:nc
    dm.xif(:,(ki-1)*nc + kj) = dm.fx{ki, kj};
  end
end

dm.xiI = zeros(nh, nc*nEigs);
nEigsTot = 0;
for k=1:nc
  nEigs = size(dm.xiPC{k}, 2);
  dm.xiI(:, nEigsTot + (1:nEigs)) = dm.xiPC{k};
  nEigsTot = nEigsTot + nEigs;
end


% Create quick mapping from date to index

M = length(dm.dates);

firstDate = dm.dates(1); % First date when time zero is included
lastDate = dm.dates(end);

dm.indAllDates = ones(lastDate-firstDate+1,1)*NaN;
dm.indAllDates(dm.dates-firstDate+1) = 1:M;

% Currencies: Create mapping from (i,j) index for to i index

tmp = zeros(nc);
tmp(:) = 1:nc*nc;
dm.curMat2vec = tmp';

% Create total return on bank account for each day

Nc = length(dm.cName);

dm.R = ones(M, Nc)*NaN; % Last row should not be used
for i=1:M-1
  for k=1:Nc
    nD = dm.dates(i+1)-dm.dates(i);
    dm.R(i,k) = exp(sum(dm.fH{k}(i, 1:nD))*dm.dt);
  end  
end

