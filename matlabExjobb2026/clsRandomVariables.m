classdef clsRandomVariables < handle
   properties
      randomVariables = {};
   end
   properties (Dependent) % Values that are calculated
   end
   
   methods
      function obj = clsRandomVariables()
      end % clsRandomVariables constructor
   end
   
   
   methods
     function [n] = add(obj, rv)
         n = length(obj.randomVariables)+1;
         obj.randomVariables{n} = rv;
      end

      function [xi] = states(obj, dm)
        M = length(dm.dates);
        N = length(obj.randomVariables);
        xi = zeros(M,N);
        for j=1:N
          o = obj.randomVariables{j};
          [xi(:,j)] = o.state(dm);
        end
      end
      
   end
   
   methods (Access = 'private') % Access by class members only

   end
end % classdef

