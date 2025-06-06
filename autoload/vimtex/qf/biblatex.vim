" VimTeX - LaTeX plugin for Vim
"
" Maintainer: Karl Yngve Lervåg
" Email:      karl.yngve@gmail.com
"

function! vimtex#qf#biblatex#addqflist(blg) abort " {{{1
  if get(g:vimtex_quickfix_blgparser, 'disable') | return | endif

  try
    call s:qf.addqflist(a:blg)
  catch /biblatex Aborted/
  endtry
endfunction

" }}}1


let s:qf = {
      \ 'file' : '',
      \ 'types' : [],
      \ 'db_files' : [],
      \}

function! s:qf.set_errorformat() abort dict "{{{1
  setlocal errorformat=%+E%.%#\>\ ERROR%m
  setlocal errorformat+=%+W%.%#\>\ WARN\ -\ Duplicate\ entry%m
  setlocal errorformat+=%+W%.%#\>\ WARN\ -\ The\ entry%.%#cannot\ be\ encoded%m
  setlocal errorformat+=%+I%.%#\>\ INFO\ -\ Found\ BibTeX\ data\ source\ %f
  setlocal errorformat+=%-G%.%#
endfunction

" }}}1
function! s:qf.addqflist(blg) abort dict " {{{1
  let self.file = a:blg
  let self.root = fnamemodify(a:blg, ':h')
  if empty(self.file) | throw 'biblatex Aborted' | endif

  let self.types = map(
        \ filter(items(s:), 'v:val[0] =~# ''^type_'''),
        \ 'v:val[1]')
  let self.db_files = []

  call vimtex#qf#u#caddfile(self, fnameescape(self.file))

  call self.fix_paths()
endfunction

" }}}1
function! s:qf.fix_paths() abort dict " {{{1
  let l:qflist = getqflist()
  try
    let l:title = getqflist({'title': 1})
  catch /E118/
    let l:title = 'VimTeX errors'
  endtry

  if has_key(self, '__state_bibfile')
    unlet self.__state_bibfile
  endif

  for l:qf in l:qflist
    for l:type in self.types
      if l:type.fix(self, l:qf) | break | endif
    endfor
  endfor

  call filter(l:qflist, { _, x -> !has_key(x, 'removeThis') })

  call setqflist(l:qflist, 'r')

  " Set title if supported
  try
    call setqflist([], 'r', l:title)
  catch
  endtry
endfunction

" }}}1
function! s:qf.get_db_files() abort dict " {{{1
  if empty(self.db_files)
    let l:preamble = vimtex#parser#preamble(b:vimtex.tex, {
          \ 'root' : b:vimtex.root,
          \})
    let l:files = map(
          \ filter(l:preamble, 'v:val =~# ''\\addbibresource'''),
          \ 'matchstr(v:val, ''{\zs.*\ze}'')')
    let self.db_files = []
    for l:file in l:files
      if filereadable(l:file)
        let self.db_files += [l:file]
      elseif filereadable(expand(l:file))
        let self.db_files += [expand(l:file)]
      else
        let l:cand = vimtex#kpsewhich#run(l:file)
        if len(l:cand) == 1
          let self.db_files += [l:cand[0]]
        endif
      endif
    endfor
  endif

  return self.db_files
endfunction

" }}}1
function! s:qf.get_filename(name) abort dict " {{{1
  if !filereadable(a:name)
    for l:root in [self.root, b:vimtex.root]
      let l:candidate = fnamemodify(simplify(l:root . '/' . a:name), ':.')
      if filereadable(l:candidate)
        return l:candidate
      endif
    endfor
  endif

  return get(self, '__state_bibfile', '')
endfunction

" }}}1
function! s:qf.get_key_pos(key) abort dict " {{{1
  for l:file in self.get_db_files()
    let l:lnum = self.get_key_lnum(a:key, l:file)
    if l:lnum > 0
      return [l:file, l:lnum]
    endif
  endfor

  return []
endfunction

" }}}1
function! s:qf.get_key_lnum(key, filename) abort dict " {{{1
  if !filereadable(a:filename) || getfsize(a:filename) > 200000
    return 0
  endif

  let l:lines = readfile(a:filename)
  let l:lnums = range(len(l:lines))
  let l:annotated_lines = map(l:lnums, '[v:val, l:lines[v:val]]')
  let l:matches = filter(l:annotated_lines,
        \ {_, x -> x[1] =~# '^\s*@\w*{\s*\V' . a:key})

  return len(l:matches) > 0 ? l:matches[-1][0]+1 : 0
endfunction

" }}}1
function! s:qf.get_entry_key(filename, lnum) abort dict " {{{1
  for l:file in self.get_db_files()
    if fnamemodify(l:file, ':t') !=# a:filename | continue | endif

    let l:entry = get(filter(readfile(l:file, 0, a:lnum), 'v:val =~# ''^@'''), -1)
    if empty(l:entry) | continue | endif

    return matchstr(l:entry, '{\v\zs.{-}\ze(,|$)')
  endfor

  return ''
endfunction

" }}}1

"
" Parsers for the various warning types
"

let s:type_parse_data_source = {}
function! s:type_parse_data_source.fix(ctx, entry) abort " {{{1
  if a:entry.text =~# 'INFO - Found BibTeX data source'
    let a:entry.removeThis = 1

    let l:file = matchstr(a:entry.text, 'BibTeX data source ''\zs.*\ze''$')
    let a:ctx.__state_bibfile = l:file

    return 1
  endif
endfunction

" }}}1

let s:type_parse_error = {}
function! s:type_parse_error.fix(ctx, entry) abort " {{{1
  if a:entry.text =~# 'ERROR - BibTeX subsystem.*expected end of entry'
    let l:matches = matchlist(a:entry.text, '\v(\S*\.%(bib|utf8)).*line (\d+)')
    if empty(l:matches) | return 1 | endif

    let a:entry.filename = a:ctx.get_filename(fnamemodify(l:matches[1], ':t'))
    let a:entry.lnum = l:matches[2]

    if empty(a:entry.filename)
      unlet a:entry.filename
      let l:key = ''
    else
      " Use filename and line number to get entry name
      let l:key = a:ctx.get_entry_key(a:entry.filename, a:entry.lnum)
    endif

    if !empty(l:key)
      let a:entry.text = 'biblatex: Error parsing entry with key "' . l:key . '"'
    else
      let a:entry.text = 'biblatex: Error parsing entry ('
            \ . matchstr(a:entry.text, '\vsyntax error: \zs.*\ze \(skipping')
            \ . ')'
    endif

    return 1
  endif
endfunction

" }}}1

let s:type_duplicate = {}
function! s:type_duplicate.fix(ctx, entry) abort " {{{1
  if a:entry.text =~# 'WARN - Duplicate entry'
    let l:matches = matchlist(a:entry.text, '\v: ''(\S*)'' in file ''(.{-})''')
    let l:key = l:matches[1]
    let a:entry.filename = a:ctx.get_filename(l:matches[2])
    let a:entry.lnum = a:ctx.get_key_lnum(l:key, a:entry.filename)
    let a:entry.text = 'biblatex: Duplicate entry key "' . l:key . '"'
    return 1
  endif
endfunction

" }}}1

let s:type_no_driver = {}
function! s:type_no_driver.fix(ctx, entry) abort " {{{1
  if a:entry.text =~# 'No driver for entry type'
    let l:key = matchstr(a:entry.text, 'entry type ''\v\zs.{-}\ze''')
    let a:entry.text = 'biblatex: Using fallback driver for ''' . l:key . ''''

    let l:pos = a:ctx.get_key_pos(l:key)
    if !empty(l:pos)
      let a:entry.filename = a:ctx.get_filename(l:pos[0])
      let a:entry.lnum = l:pos[1]
      if has_key(a:entry, 'bufnr')
        unlet a:entry.bufnr
      endif
    endif

    return 1
  endif
endfunction

" }}}1

let s:type_not_found = {}
function! s:type_not_found.fix(ctx, entry) abort " {{{1
  if a:entry.text =~# 'The following entry could not be found'
    let l:key = split(a:entry.text, ' ')[-1]
    let a:entry.text = 'biblatex: Entry with key ''' . l:key . ''' not found'

    for [l:file, l:lnum, l:line] in vimtex#parser#tex(b:vimtex.tex)
      if l:line =~# g:vimtex#re#not_comment . '\\\S*\V' . l:key
        let a:entry.lnum = l:lnum
        let a:entry.filename = l:file
        unlet a:entry.bufnr
        break
      endif
    endfor

    return 1
  endif
endfunction

" }}}1

let s:type_encoding = {}
function! s:type_encoding.fix(ctx, entry) abort " {{{1
  if a:entry.text =~# 'The entry .* has characters which cannot'
    let l:key = matchstr(a:entry.text, 'The entry ''\v\zs.{-}\ze''')
    let a:entry.text = 'biblatex: Entry with key ''' . l:key . ''' has non-ascii characters'

    let l:pos = a:ctx.get_key_pos(l:key)
    if !empty(l:pos)
      let a:entry.filename = a:ctx.get_filename(l:pos[0])
      let a:entry.lnum = l:pos[1]
      if has_key(a:entry, 'bufnr')
        unlet a:entry.bufnr
      endif
    endif

    return 1
  endif
endfunction

" }}}1
