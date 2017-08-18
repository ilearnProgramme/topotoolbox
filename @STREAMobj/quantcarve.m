function [zs,output] = quantcarve(S,DEM,tau,varargin)

%QUANTCARVE quantile carving
%
% Syntax
%
%     zs = quantcarve(S,DEM,tau)
%     zs = quantcarve(S,z,tau)
%     zs = quantcarve(...,pn,pv,...)
%     [zs,output] = ...
%
%
% Description
%
%     Elevation values along stream networks are frequently affected by
%     large scatter, often as a result of data artifacts or errors. This
%     function returns a node attribute list of elevations calculated by
%     carving the DEM. Conversely to conventional carving, quantcarve will
%     not run along minimas of the DEM. Instead, quantcarve returns a
%     profile that runs along the tau's quantile of elevation conditional 
%     horizontal distance of the river profile.
%
%     The function uses linprog from the Optimization Toolbox.
%
% Input parameters
%
%     S      STREAMobj
%     DEM    Digital elevation model (GRIDobj)
%     tau    quantile (default is 0.5)
%     
%     Parameter name/value pairs {default}
%
%     'mingradient'   positive scalar {0}. Minimum downward gradient. 
%                     Choose carefully, because length profile may dip to
%                     steeply. 
%     'split'         {true} or false. If set to true, quantcarve will
%                     split the network into individual drainage basins and 
%                     process them in parallel.
%
%
% Output parameters
%
%     zs       node attribute list with smoothed elevation values
%     output   structure array with information about the optimization
%              progress
%
% Example
%
%     DEM = GRIDobj('srtm_bigtujunga30m_utm11.tif');
%     FD = FLOWobj(DEM,'preprocess','carve');
%     S = STREAMobj(FD,'minarea',1000);
%     S = klargestconncomps(S);
%     S = trunk(S);
%     zs50  = quantcarve(S,DEM,0.5);
%     zs90  = quantcarve(S,DEM,0.9);
%     zs10  = quantcarve(S,DEM,0.1);
%     plotdz(S,DEM,'color',[0.6 0.6 0.6])
%     hold on
%     plotdzshaded(S,[zs90 zs10]);
%     plotdz(S,zs50,'color','k','LineWidth',1.5)
%     hold off
%
%
% See also: STREAMobj/mincosthydrocon, quadprog, profilesimplify
% 
% Author: Wolfgang Schwanghart (w.schwanghart[at]geo.uni-potsdam.de)
% Date: 18. July, 2017

% check and parse inputs
narginchk(2,inf)

if nargin == 2
    tau = 0.5;
end

p = inputParser;
p.FunctionName = 'STREAMobj/quantcarve';
addParameter(p,'split',2);
addParameter(p,'mingradient',0,@(x) isscalar(x) && x>=0);
addParameter(p,'fixedoutlet',false);
parse(p,varargin{:});

validateattributes(tau,{'numeric'},{'>',0,'<',1},'STREAMobj/quantcarve','tau',3);

% get node attribute list with elevation values
if isa(DEM,'GRIDobj')
    validatealignment(S,DEM);
    z = getnal(S,DEM);
elseif isnal(S,DEM);
    z = DEM;
else
    error('Imcompatible format of second input argument')
end

if any(isnan(z));
    error('DEM or z may not contain any NaNs')
end

z = double(z);

%% Run in parallel
if p.Results.split == 1
    params = p.Results;
    params.split = false;
    [CS,locS] = STREAMobj2cell(S);
    if numel(CS) > 1
        % run only in parallel if more than one drainage basin
        Cz = cellfun(@(ix) z(ix),locS,'UniformOutput',false);
        Czs = cell(size(CS));
        parfor r = 1:numel(CS)
            Czs{r} = quantcarve(CS{r},Cz{r},tau,params);
        end
        
        zs = nan(size(z));
        for r = 1:numel(CS)
            zs(locS{r}) = Czs{r};
        end
        return
    else
        zs = quantcarve(S,z,tau,params);
        return
    end
    
elseif p.Results.split == 2
    
    params = p.Results;
    params.split = 1;
    
    St = trunk(S);    
    [~,locb]  = ismember(St.IXgrid,S.IXgrid);
    zt = z(locb);
    
    zst = quantcarve(St,zt,tau,params);
    z(locb) = zst;
    
    params.split = 0;
    
    params.fixedoutlet = true;
    Stribs = modify(S,'tributaryto2',St);
    Stribs = STREAMobj2cell(Stribs);
    [~,locb]   = cellfun(@(Stt) ismember(Stt.IXgrid,S.IXgrid),Stribs,'UniformOutput',false);
    ztribs = cellfun(@(ix) z(ix),locb,'UniformOutput',false);
    
    Czs = cell(size(Stribs));
    
    n   = numel(Stribs);
    
    parfor r = 1:n
        Czs{r} = quantcarve(Stribs{r},ztribs{r},tau,params);
    end
    
    for r = 1:numel(Stribs)
        z(locb{r}) = Czs{r};
    end
    zs = z;
    return
    
end




%% Carve function starts here
% upstream distance
d  = S.distance;
% nr of nodes
n  = numel(S.IXgrid);

f   = [tau*ones(n,1);(1-tau)*ones(n,1);zeros(n,1)];
% Equalities
if ~p.Results.fixedoutlet
    Aeq = [speye(n),-speye(n),speye(n)];
else 
    OUTL = streampoi(S,'outlet','logical');
    P    = spdiags(+(~OUTL),0,n,n);
    Aeq  = [P,-P,speye(n)];
end

beq = z;
lb  = [zeros(n,1);zeros(n,1);-inf*ones(n,1)];


% gradient constraint
d = 1./(d(S.ix)-d(S.ixc));
A = [sparse(n,n*2) (sparse(S.ix,S.ixc,d,n,n)-sparse(S.ix,S.ix,d,n,n))];

if p.Results.mingradient~=0
    b = zeros(n,1);
    b(S.ix) = -p.Results.mingradient;
else
    b = sparse(n,1);
end


%% Solve the linear programme
% set options
options = optimset('Display','off','algorithm','interior-point'); %'OptimalityTolerance',1e-6,

[bhat,~,~,output] = linprog(f,A,b,Aeq,beq,lb,[],[],options);
zs = bhat(2*n+1:end);


