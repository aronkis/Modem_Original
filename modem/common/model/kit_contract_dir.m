function d = kit_contract_dir(KITDIR)
% kit_contract_dir -- the contract/ directory (ROM words, golden payloads, frame files)
% for a kit root, WITHOUT a symlink. A scratch kit has it as its sibling
% (<kit>/../contract, copied there by modem/common/tools/make_kit.sh); a tree inside
% the repo (modem/dev, modem/prod) reaches the repo's contract/ two levels up.
if nargin < 1 || isempty(KITDIR), KITDIR = pwd; end
cands = {fullfile(fileparts(KITDIR), 'contract'), fullfile(fileparts(fileparts(KITDIR)), 'contract')};
for k = 1:numel(cands)
    if isfile(fullfile(cands{k}, 'rom_words_70_k5.txt')), d = cands{k}; return; end
end
error('kit_contract_dir: no contract/ next to %s or two levels up (make_kit.sh copies it beside a scratch kit)', KITDIR);
end
