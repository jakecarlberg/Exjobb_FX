dataFolder = 'epiroc2024';

load([dataFolder '\itemNumberDictionary'], 'itemNumberDictionary', 'productNumberDictionary');

load([dataFolder '\purchaseOrder'], 'p');
load([dataFolder '\stockTransactions'], 's');
load([dataFolder '\BOM'], 'b');
load([dataFolder '\costing'], 'c');



% Find stock transaction corresponding to bom row
pn = unique(b.product);

s.jBOM = zeros(size(s,1),1); % Index to BOM on row (in b)
b.jStockTransaction = zeros(size(b,1),1); % Index to stock transaction on row (in s)
diffBomAll = [];
missp=0;
misss=0;
for i=1:length(pn)
  ib = (b.product == pn(i));
  tmp = str2num(productNumberDictionary{pn(i)},Evaluation="restricted");
  is = (s.orderNumber == tmp);
  bItemNumber = b.componentNumber(ib);
  sItemNumber = s.itemNumber(is);

  itemNumber = unique([bItemNumber ; sItemNumber]);
  for ii = 1:length(itemNumber)
    jb = find(ib & b.componentNumber == itemNumber(ii));
    js = find(is & s.itemNumber == itemNumber(ii));

    while (~isempty(jb) && ~isempty(js))
      dQ = repmat(b.quantity(jb),1, length(js)) - repmat(s.transactionQuantityBasicUM(js)', length(jb), 1);
      dT = repmat(b.reportingDate(jb),1, length(js)) - repmat(s.entryDate(js)', length(jb), 1);
      [minVal,jj] = min(dQ(:).^2+dT(:).^2);
      [jjb, jjs] = ind2sub(size(dQ),jj);
      if (minVal ~= 0)  % Not exact match
        diffBomAll = [diffBomAll ; pn(i) itemNumber(ii) b.quantity(jb(jjb)) s.transactionQuantityBasicUM(js(jjs)) b.reportingDate(jb(jjb)) s.entryDate(js(jjs)) dQ(jjb, jjs) dT(jjb, jjs)];
      end
      s.jBOM(js(jjs)) = jb(jjb);
      b.jStockTransaction(jb(jjb)) = js(jjs);
      jb(jjb) = [];
      js(jjs) = [];
    end
    for j = 1:length(jb)
      missp = missp+1;
      fprintf('For item %s, BOM %s with accounting date %s was not found\n', string(itemNumberDictionary(itemNumber((ii)))), productNumberDictionary{pn(i)}, datestr(b.reportingDate(jb(j))));
    end
    for j = 1:length(js)
      misss = misss+1;
      fprintf('For item %s, purchase order %s for stock entry on date %s was not found\n', string(itemNumberDictionary(itemNumber((ii)))), productNumberDictionary{pn(i)}, datestr(s.entryDate(js(j))));      
    end
  end

end









% Find payment corresponding to procurement
pon = unique(p.purchaseOrderNumber);

ind = find(s.stockTransactionType == 25); % Procurement


s.jPurchaseOrder = zeros(size(s,1),1); % Index to purchase order on row (in p)
p.jStockTransaction = zeros(size(p,1),1); % Index to stock transaction on row (in s)
diffAll = [];
missp=0;
misss=0;
for i=1:length(pon)
  ip = (p.purchaseOrderNumber == pon(i));
  is = (s.stockTransactionType == 25 & s.orderNumber == pon(i));
  pItemNumber = p.itemNumber(ip);
  sItemNumber = s.itemNumber(is);

  itemNumber = unique([pItemNumber ; sItemNumber]);
  for ii = 1:length(itemNumber)
    jp = find(ip & p.itemNumber == itemNumber(ii));
    js = find(is & s.itemNumber == itemNumber(ii));

    while (~isempty(jp) && ~isempty(js))
      dQ = repmat(p.invoicedQuantityAlternateUM(jp),1, length(js)) - repmat(s.transactionQuantityBasicUM(js)', length(jp), 1);
      dT = repmat(p.accountingDate(jp),1, length(js)) - repmat(s.entryDate(js)', length(jp), 1);
      [minVal,jj] = min(dQ(:).^2+dT(:).^2);
      [jjp, jjs] = ind2sub(size(dQ),jj);
      if (minVal ~= 0)  % Not exact match
        diffAll = [diffAll ; pon(i) itemNumber(ii) p.invoicedQuantityAlternateUM(jp(jjp)) s.transactionQuantityBasicUM(js(jjs)) p.accountingDate(jp(jjp)) s.entryDate(js(jjs)) dQ(jjp, jjs) dT(jjp, jjs)];
      end
      s.jPurchaseOrder(js(jjs)) = jp(jjp);
      p.jStockTransaction(jp(jjp)) = js(jjs);
      jp(jjp) = [];
      js(jjs) = [];
    end
    for j = 1:length(jp)
      missp = missp+1;
      fprintf('For item %s, purchase order %d with accounting date %s was not found\n', string(itemNumberDictionary(itemNumber((ii)))), pon(i), datestr(p.accountingDate(jp(j))));      
    end
    for j = 1:length(js)
      misss = misss+1;
      fprintf('For item %s, purchase order %d for stock entry on date %s was not found\n', string(itemNumberDictionary(itemNumber((ii)))), pon(i), datestr(s.entryDate(js(j))));      
    end
  end

  % js = find(p.purchaseOrderNumber == s.orderNumber(ind(i)) & p.itemNumber == s.itemNumber(ind(i)));
  % % One purchaseOrderNumber can contain several types of items. It can also contain multiple deliveries.
  % if (length(j) > 1)
  %   dQ = p.invoicedQuantityAlternateUM(j) - s.transactionQuantityBasicUM(ind(i));
  %   dT = p.accountingDate(j) - s.entryDate(ind(i));
  %   error('Multiple purchase orders');
  % end
  % if (isempty(j))
  %   fprintf('For item %s, purchase order %d for stock entry on date %s was not found\n', string(itemNumberDictionary(s.itemNumber(ind(i)))), s.orderNumber(ind(i)), datestr(s.entryDate(ind(i))));
  % elseif (length(j) > 1)
  %   error('Multiple purchase orders');
  % else
  %   s.jPurchaseOrder(ind(i)) = j;
  %   p.jStockTransaction(j) = ind(i);
  %   if (s.transactionQuantityBasicUM(ind(i)) ~= p.invoicedQuantityAlternateUM(j))
  %     error('Order amount and delivered amount differ');
  %   end
  %   if (abs(s.entryDate(ind(i)) - p.accountingDate(j)) >= 60)
  %     error(['Stock date and accounting date differ ' datestr(s.entryDate(ind(i))) ' ' datestr(p.accountingDate(j))]);
  %   end
  % end
end

ind = find(s.stockTransactionType == 25); % Procurement
fprintf('Stock increase missing procurement: %d/%d = %.2f%%\n', sum(s.jPurchaseOrder(ind)==0), length(ind), sum(s.jPurchaseOrder(ind)==0)/length(ind)*100)
fprintf('Procuremnt missing stock increase: %d/%d = %.2f%%\n', sum(p.jStockTransaction==0), size(p,1), sum(p.jStockTransaction==0)/size(p,1)*100)

indE = (s.stockTransactionType == 25 & s.jPurchaseOrder == 0);
tmps = sort(s.entryDate(indE));
indE = (p.jStockTransaction == 0);
tmpp = sort(p.accountingDate(indE));
plot(tmps, (1:length(tmps))/length(tmps), tmpp, (1:length(tmpp))/length(tmpp));
datetick('x', 'yyyy');



