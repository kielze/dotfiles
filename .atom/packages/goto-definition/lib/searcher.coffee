child_process = require 'child_process'

module.exports = class Searcher

  @transformUnsavedMatch: (match) ->
    all_lines = match.match.input.split(/\r\n|\r|\n/)
    lines = match.match.input.substring(0, match.match.index + 1).split(/\r\n|\r|\n/)
    line_number = lines.length - 1

    return {
      text: all_lines[line_number],
      line: line_number,
      column: lines.pop().length
    }

  @filterMatch: (match) ->
    return match isnt null and match.text.trim().length < 350

  @fixColumn: (match) ->
    if (match.column is 1) and (/^\s/.test(match.text) is false) # ripgrep's bug
      match.column = 0
    head_empty_chars = /^[\s\.]/.exec(match.text.substring(match.column))?[0] ? ''
    return {
      text: match.text,
      fileName: match.fileName,
      line: match.line,
      column: match.column + head_empty_chars.length
    }

  @atomBufferScan: (file_types, regex, iterator, callback) ->
    # atomBufferScan just search opened files
    panels = atom.workspace.getPaneItems()
    callback(panels.map((editor) ->
      if editor.constructor.name is 'TextEditor'
        file_path = editor.getPath()
        if file_path
          file_extension = '*.' + file_path.split('.').pop()
          if file_extension in file_types
            editor.scan new RegExp(regex, 'ig'), (match) ->
              item = Searcher.transformUnsavedMatch(match)
              item.fileName = file_path
              iterator([Searcher.fixColumn(item)].filter(Searcher.filterMatch))
          return file_path
      return null
    ).filter((x) -> x isnt null))

  @atomWorkspaceScan: (scan_paths, file_types, regex, iterator, callback) ->
    @atomBufferScan file_types, regex, iterator, (opened_files) ->
      atom.workspace.scan(new RegExp(regex, 'ig'), { paths: file_types }, (result, error) ->
        return if opened_files.includes(result.filePath) # atom.workspace.scan can't set exclusions
        iterator(result.matches.map((match) -> {
          text: match.lineText,
          fileName: result.filePath,
          line: match.range[0][0],
          column: match.range[0][1]
        }).filter(Searcher.filterMatch).map(Searcher.fixColumn))
      ).then(callback)

  @ripgrepScan: (scan_paths, file_types, regex, iterator, callback) ->
    @atomBufferScan file_types, regex, iterator, (opened_files) ->
      args = file_types.map((x) -> '--glob=' + x)
      args.push.apply(args, opened_files.map((x) -> '--glob=!' + x))
      args.push.apply(args, [
        '--line-number', '--column', '--no-ignore-vcs', '--ignore-case',
        regex, scan_paths.join(',')
      ])

      run_ripgrep = child_process.spawn('rg', args)

      run_ripgrep.stdout.setEncoding('utf8')
      run_ripgrep.stderr.setEncoding('utf8')

      run_ripgrep.stdout.on 'data', (results) ->
        iterator(results.split('\n').map((result) ->
          if result.trim().length
            data = result.split(':')
            return {
              text: result.substring([data[0], data[1], data[2]].join(':').length + 1),
              fileName: data[0],
              line: Number(data[1] - 1),
              column: Number(data[2])
            }
          else
            return null
        ).filter(Searcher.filterMatch).map(Searcher.fixColumn))

      run_ripgrep.stderr.on 'data', (message) ->
        return if message.includes('No files were searched')
        throw message

      run_ripgrep.on 'close', callback

      run_ripgrep.on 'error', (error) ->
        if error.code is 'ENOENT'
          atom.notifications.addWarning('Plase install `ripgrep` first.')
        else
          throw error

      setTimeout(run_ripgrep.kill.bind(run_ripgrep), 10 * 1000)
