function [dm, dc] = xi2structure(dm, dc, version) 
% version == 1: Used to compute derivatives
% version == 2: Used to shift t-1 to t
% version == 3: Used to shift t-1 to t + add changes of significant risk factors

if(nargin == 2)
  version = 1;
end

if (version == 2)
  dc.xi(2:end,:) = dc.xi(1:end-1,:);  
end

% Copy values in xi to all duplicate copies in dm and dc

nc = length(dm.cName);

% Reverse dc.xi = [dm.xif dm.xiI dc.xiP]
dm.xif = dc.xi(:, 1:nc*nc);
nPC = size(dm.xiI,2);
dm.xiI = dc.xi(:, nc*nc + (1:nPC));
nP = size(dc.xiP,2);
dc.xiP = dc.xi(:, nc*nc + nPC + (1:nP));


% Reverse dc.xif = ...

j = 1;
for ki=1:nc
  for kj=1:nc
    dm.fx{ki, kj} = dm.xif(:,(ki-1)*nc + kj);
  end
end

% Reverse dc.xiI = ...

xiPC = dm.xiPC;

nEigsTot = 0;
for k=1:nc
  nEigs = size(dm.xiPC{k}, 2);
  dm.xiPC{k} = dm.xiI(:, nEigsTot + (1:nEigs));
  nEigsTot = nEigsTot + nEigs;
end

% Update discount factors according to change in xiPC

for k=1:nc
  if (version == 1)
    dxi = dm.xiPC{k} - xiPC{k};
    dm.d{k} = dm.d{k}.*exp(dxi*dm.negIntE{k}');
  elseif (version == 2)
    dm.d{k}(2:end,:) = dm.d{k}(1:end-1,:);    
  elseif (version == 3)
    dxi = dm.xiPC{k}(2:end,:) - dm.xiPC{k}(1:end-1,:);
    dm.d{k}(2:end,:) = dm.d{k}(1:end-1,:).*exp(dxi*dm.negIntE{k}');
  end
end

