rng(1); 

curHome = 'SEK';
% curSales = 'USD';
curSales = 'SEK';

iCurHome = find(ismember(dm.cName, curHome));
iCurSales = find(ismember(dm.cName, curSales));


startDate = datenum(2020,09,14);
endDate = datenum(2024,05,03);
% endDate = datenum(2024,02,03);

marginInventory = 0.1; % Procurement is done at the price c/(1+marginInventory), where c is the costing price
marginSales = 0.1; % Procurement is done at the price c/(1+marginInventory), where c is the costing price

dates = startDate:endDate;
wd = weekday(dates);
dates(wd == 1 | wd == 7) = []; % Remove Sundays and Saturdays
nDates = length(dates);

nComponents = 10;
% nComponents = 1;

% Generate component prices
cNames = {'facility', 'itemNumber', 'costingDate', 'CostingSum1' };

dt = (endDate-startDate)/(365*nDates);
cMu = ones(nComponents,1)*0.02*dt;
cSigma = ones(nComponents,1)*0.01*sqrt(dt);
cPricesInit = ceil(rand(nComponents,1)*100);
cPrices = repmat(cPricesInit', nDates,1).*exp(cumsum(repmat(cMu', nDates,1) + randn(nDates,nComponents).*repmat(cSigma', nDates,1)));

costing = [(1:nComponents)' ones(nComponents,1)*startDate cPricesInit];
cPricesQ = cPrices;
for i=2:nDates
  mo = month(dates(i));
  if (month(dates(i-1)) ~= mo && (mo == 1 || mo == 4 || mo == 7 || mo == 10) )
    costing = [costing ; (1:nComponents)' ones(nComponents,1)*dates(i) cPrices(i,:)'];
  else
    cPricesQ(i,:) = cPricesQ(i-1,:);
  end
end

c = table(ones(size(costing,1),1), costing(:,1), costing(:,2), costing(:,3), 'VariableNames',cNames);

save('simulatedData\costing', 'c');

% Generate BOM structures

bNames = {'product', 'componentNumber', 'quantity', 'referenceOrderNumber', 'reportingDate', 'costPrice', 'actualFinishDate', 'CostPriceValue' };

bmQuantity = ceil(rand(nComponents,1)*10);
bmDates = sort(ceil(rand(nComponents,1)*10)); 
bMaster = table(ones(nComponents, 1), (1:nComponents)', bmQuantity, zeros(nComponents,1), bmDates, inf(nComponents,1), bmDates, inf(nComponents,1),'VariableNames',bNames);

nBOM = 20;
% nBOM = 1;

bDate = sort(ceil(rand(nBOM,1)*(nDates-(max(bmDates)+10))));
productOrderDate = zeros(nBOM,1);

for i=1:nBOM
  orderDate = dm.dates(max(min(bMaster.actualFinishDate)-4*7, 1)); % (4 weeks earlier)
  productOrderDate(i) = orderDate;  
  iOrderDate = dm.indAllDates(productOrderDate(i)-dm.dates(1)+1);

  bTmp = bMaster;
  bTmp.product = bMaster.product*i;
  bTmp.reportingDate = dates(bDate(i) + bMaster.reportingDate)';
  bTmp.actualFinishDate = dates(bDate(i) + bMaster.actualFinishDate)';
  bTmp.costPrice = cPricesQ(iOrderDate,:)';
  bTmp.CostPriceValue = bMaster.quantity.*cPricesQ(i,:)';
  if (i==1)
    b = bTmp;
  else
    b = [b ; bTmp];
  end
end

save('simulatedData\BOM', 'b', 'productOrderDate');

% Generate sales and accounts receivable

saNames = {'invoiceNumber', 'itemNumber', 'foreignCurrencyAmount', 'lineAmountLocalCurrency', 'costPrice', 'currency'};
sa = table((1:nBOM)', (1:nBOM)', zeros(nBOM,1), zeros(nBOM,1), zeros(nBOM,1), cell(nBOM,1), 'VariableNames',saNames);

aNames = {'invoiceNumber', 'transactionCode', 'foreignCurrencyAmount', 'currency', 'dueDate', 'accountingDate'};
a = table(zeros(2*nBOM,1), zeros(2*nBOM,1), zeros(2*nBOM,1), cell(2*nBOM,1), zeros(2*nBOM,1), zeros(2*nBOM,1), 'VariableNames',aNames);

for i=1:nBOM
  ind = (b.product==i);
  
  iOrderDate = dm.indAllDates(productOrderDate(i)-dm.dates(1)+1);

  sa.costPrice(i) = sum(b.CostPriceValue(ind));
  sa.lineAmountLocalCurrency(i) = sa.costPrice(i)*(1+marginSales);
  sa.foreignCurrencyAmount(i) = sa.lineAmountLocalCurrency(i)*dm.fx{iCurHome, iCurSales}(iOrderDate);
  sa.currency(i) = {curSales};

  a.invoiceNumber(2*(i-1)+1) = i;
  a.transactionCode(2*(i-1)+1) = 10;
  a.foreignCurrencyAmount(2*(i-1)+1) = sa.foreignCurrencyAmount(i);
  a.currency(2*(i-1)+1) = {curSales};
  a.accountingDate(2*(i-1)+1) = max(b.actualFinishDate(ind))+7; % When invoice is sent
  a.dueDate(2*(i-1)+1) = a.accountingDate(2*(i-1)+1)+8*7;     % When invoice should be paid (8 weeks)

  a.invoiceNumber(2*(i-1)+2) = i;
  a.transactionCode(2*(i-1)+2) = 20;
  a.foreignCurrencyAmount(2*(i-1)+2) = -sa.foreignCurrencyAmount(i);   
  a.currency(2*(i-1)+2) = {curSales};
  a.dueDate(2*(i-1)+2) = a.accountingDate(2*(i-1)+1)+8*7;        % When invoice should be paid (8 weeks)
  a.accountingDate(2*(i-1)+2) = a.accountingDate(2*(i-1)+1)+8*7; % When invoice is paid (8 weeks)
  
end

save('simulatedData\Sales', 'sa');
save('simulatedData\AccountsReceivable', 'a');

% Generate stock (inventory) and procurement
sNames = {'itemNumber', 'stockTransactionType', 'newOnHandBalance', 'transactionQuantityBasicUM', 'entryDate', 'orderNumber', 'impliedOnHandBalance' };
pNames = {'purchaseOrderNumber', 'itemNumber', 'transactionCode', 'currency', 'purchaseOrderNumber_1', 'invoicedQuantityAlternateUM', 'accountingDate', 'dueDate', 'lineAmountOrderCurrency' };

p = array2table(zeros(0,length(pNames)));
p.Properties.VariableNames = pNames;

% sInit = 10+ceil(rand(nComponents,1)*100);
sInit = zeros(nComponents,1); % Start with zero inventory, which enforce procurement in the beginning (otherwise problem with clsXiLastProcurement which is used)

s = table(b.componentNumber, 11*ones(size(b,1),1), zeros(size(b,1),1), -b.quantity, b.reportingDate, b.product, zeros(size(b,1),1), 'VariableNames', sNames);

pi = 1;
if (exist('sp', 'var'))
  clear sp;
end
for j=1:nComponents
  ind = find(s.itemNumber == j);
  stock = sInit(j)+cumsum(s.transactionQuantityBasicUM(ind));
  for i=1:length(ind)
    if (stock(i) <= 0)
      qBuy = 100;
      ii = find(dates == b.reportingDate(ind(i)));
      pTmp = table(pi, j, 40, {'SEK'}, pi, qBuy, s.entryDate(ind(i)), s.entryDate(ind(i))+60, cPrices(ii,j)/(1+marginInventory)*qBuy, 'VariableNames', pNames);
      p = [p ; pTmp];
      sTmp = table(j, 25, 0, qBuy, s.entryDate(ind(i)), pi, 0, 'VariableNames', sNames);
      if (exist('sp', 'var'))
        sp = [sp ; sTmp];
      else
        sp = sTmp;
      end
      pi = pi+1;
      stock(i:end) = stock(i:end) + qBuy;
    end
  end
end

s = [sp ; s];
[~, ind] = sort(s.entryDate);
s = s(ind,:);

for j=1:nComponents
  ind = find(s.itemNumber == j);
  stock = sInit(j)+cumsum(s.transactionQuantityBasicUM(ind));
  s.newOnHandBalance(ind) = stock;
  s.impliedOnHandBalance(ind) = stock;
end

% Some dueDates on weekends - move backwards to Friday
wd = weekday(p.dueDate);
p.dueDate(wd == 7) = p.dueDate(wd == 7) - 1; % Saturday -> Friday
p.dueDate(wd == 1) = p.dueDate(wd == 1) - 2; % Sunday -> Friday

save('simulatedData\stockTransactions', 's');
save('simulatedData\purchaseOrder', 'p');

itemNumberDictionary = cellstr(num2str((1:nComponents)', '%010.0f'));
productNumberDictionary = cellstr(num2str((1:nBOM)', '%010.0f'));

save('simulatedData\itemNumberDictionary', 'itemNumberDictionary', 'productNumberDictionary');
