function KITDIR = kitpath(KITDIR)
% kitpath -- put a kit root and its stage folders on the MATLAB path.
%
%   KITDIR = kitpath(KITDIR)   adds KITDIR and every stage folder that exists under it
%                              (simulink/, simulink/beatila, simulink/rxfix, hdlcoder/,
%                              simgate/, hdlsim/, derive/, edit/), kit LAST so its
%                              parameter functions win over toolbox defaults.
%
% Every kit entry point (build_variant_byte.m, the gates, the assemblers) calls this
% right after cd(KITDIR). The kit-root contract keeps the shared parameter/init/byte-
% plane functions under <kit>/model (modem/common/model in the repo). Safe to call
% repeatedly. See also kit_contract_dir.m.
if nargin < 1 || isempty(KITDIR), KITDIR = pwd; end
sub = {'simulink', fullfile('simulink','beatila'), fullfile('simulink','rxfix'), ...
       'hdlcoder', 'simgate', 'hdlsim', 'derive', 'edit'};
addpath(KITDIR);
for k = 1:numel(sub)
    d = fullfile(KITDIR, sub{k});
    if isfolder(d), addpath(d); end
end
% the shared MATLAB files: <kit>/model in a scratch kit (make_kit.sh), or the repo's
% modem/common/model when this runs inside modem/dev or modem/prod (no symlinks anywhere)
shared = {fullfile(KITDIR, 'model'), fullfile(fileparts(KITDIR), 'common', 'model')};
for k = 1:numel(shared)
    if isfolder(shared{k}), addpath(shared{k}); break; end
end
% prod inside the repo borrows dev's frame-generic analysers (a kit gets real copies)
if ~isfile(fullfile(KITDIR, 'simgate', 'gen_byte_vectors_k5.m'))
    dv = fullfile(fileparts(KITDIR), 'dev');
    for d = {fullfile(dv,'simgate'), fullfile(dv,'hdlsim')}
        if isfolder(d{1}), addpath(d{1}); end
    end
end
end
