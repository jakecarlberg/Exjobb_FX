function [dates, firstDates, lastDates, fH, ricAll, zH] = forwardRates(currencyName, firstDate, p)

% --- AMPL paths (update to match your installation) ----------------------
amplFolderPath = '/Applications/AMPL';
amplSetupFilename = fullfile(amplFolderPath, 'amplapi', 'matlab', 'setUp.m');
amplPath = amplFolderPath;  % ampl binary is in the root folder on Mac
solverFile = fullfile(amplPath, 'ipopt');

if (~exist(amplSetupFilename,'file') || ~exist(amplPath, 'dir'))
  error('AMPL not found. Update amplFolderPath in forwardRates.m to your AMPL installation path.');
end

ipoptFilename = fullfile(amplFolderPath, 'ipopt');
if (~exist(ipoptFilename,'file'))
  error('Ipopt solver not found. Place the ipopt binary in your AMPL folder.');
end

if (~exist('AMPL', 'file')) % Only initialize ampl once
  run(amplSetupFilename);
%   run /sw/cplex/amplapi/matlab/setUp
end

if (exist('ampl', 'var')) % Ensure that ampl is closed if matlab program ended prematurely the previous time
  ampl.close();
  clear ampl;
end

fileName = strcat(currencyName, "Z.xlsx");
[dates, ricAll, tenor, maturityDates, zeroRates] = loadFromExcel(fileName);
ind = (dates >= firstDate);
dates = dates(ind);
maturityDates = maturityDates(ind,:);
zeroRates = zeroRates(ind,:);

% Remove Saturdays and Sundays from market data

wd = weekday(dates);
ind = ((wd >= 2) & (wd <= 6)); % Keep Monday to Friday
dates = dates(ind);
maturityDates = maturityDates(ind,:);
zeroRates = zeroRates(ind,:);


dt = 1/365; % Daily discretization in forward rates
% maxT = 2.1;
maxT = 10.1;
nFmax = ceil(maxT/dt);

nOIS = length(ricAll);

K = length(dates); % Number of historical dates
fH = zeros(K, nFmax);
zH = zeros(K, nOIS);
firstDates = zeros(K,1);
lastDates = zeros(K,1);
flgKeep = true(K,1);

figure(1);
for k=1:K
  T = (maturityDates(k,:)-dates(k))'*dt;
  ind = (~isnan(zeroRates(k,:)') & T < maxT & T >= 0); % For Rubels days are sometimes 100 years off
  if (sum(ind) < 1)
    flgKeep(k) = false;
    continue;
  end
  M = maturityDates(k,ind)'-dates(k); % Maturities (measured in number of time periods)
  r = log(1+zeroRates(k,ind)');
  T = M*dt;
  f = [r(1) ; (r(2:end).*T(2:end)-r(1:end-1).*T(1:end-1))./(T(2:end)-T(1:end-1))];
  nF = M(end);
  firstDates(k) = dates(k);
  lastDates(k) = firstDates(k) + nF;

  knowledgeHorizon = 2; % After knowledge horizon second order derivative have equal weight
  informationDecrease = 2; % How much information decrease in one year
%   cb = ones(nF-1,1);
  cb = ones(nFmax-1,1);
  allT = (1:length(cb))'*dt;
  cb(1:min(round(knowledgeHorizon*365),length(cb))) = exp((allT(1:min(round(knowledgeHorizon*365),length(cb)))-knowledgeHorizon)*log(informationDecrease^2));
  cb(1) = 0;
  cb(:) = 1;

  try
    ampl = AMPL(amplPath);
    ampl.read('forwardRatesLS.mod')
    ampl.getParameter('p').set(p);
    ampl.getParameter('dt').set(dt);

    ampl.getParameter('n').set(nF);
    ampl.getParameter('m').set(length(T));
    ampl.getParameter('M').setValues(M);

    ampl.getParameter('r').setValues(r);
    ampl.getParameter('cb').setValues(cb(1:nF-1));
    ampl.setOption('solver', solverFile)
    ampl.solve();

    T0 = [0 ; T];
    [xx,yy] = stairs(T0, [f ; f(end)]);

    fS = ampl.getVariable('f').getValues().getColumnAsDoubles('f.val'); % Smooth forward rates
    z = ampl.getVariable('z').getValues().getColumnAsDoubles('z.val'); % Price errors
    midT = (T0(1:end-1)+T0(2:end))/2;
    plot(xx,yy, (0:M(end)-1)*dt, fS, midT, fS(1+round(midT*1/dt))+z, '+'); % + indicates the direction that forward rates should be adjusted
    title([char(currencyName) ' (p = ' sprintf('%.0e',p) '), ' datestr(dates(k))]);

    pause(.1); % Pause 0.1 second (to be able to view the curve)
    fH(k,1:nF) = fS;
    zH(k,ind) = z;

    ampl.close();
    clear ampl;
  catch ME
    fprintf('%s: Skipping date %s - AMPL error: %s\n', char(currencyName), datestr(dates(k)), ME.message);
    flgKeep(k) = false;
    try, ampl.close(); catch, end
    try, clear ampl; catch, end
  end
end

dates = dates(flgKeep);
fH = fH(flgKeep,:);
zH = zH(flgKeep,:);
firstDates = firstDates(flgKeep);
lastDates = lastDates(flgKeep);


