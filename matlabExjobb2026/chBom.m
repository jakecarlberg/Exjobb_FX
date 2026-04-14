dataFolder = 'epiroc2024';

load(fullfile(dataFolder, 'BOM'), 'b');

[productId,ia,ic] = unique(b.product);

nRows = zeros(length(productId),1);
for i=1:length(ic)
  nRows(ic(i)) = nRows(ic(i))+1;
end

