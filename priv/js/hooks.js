/**
 * SPDX-FileCopyrightText: 2026 Luke Galea
 * SPDX-License-Identifier: MIT
 *
 * The package's LiveView hooks, for hosts to register (see README).
 */

// `events`: every event name the hook passes to handleEvent; a host that loads
// the hook lazily subscribes to these before the code arrives, because the hook
// subscribes in mounted() and a server push must have somewhere to land while
// the code is still in flight. `load`: fetches the hook's code and resolves to
// the hook object.
//
// No top-level imports: hosts include this file on every page, so an import
// here would pull dmn-js into every page whether or not the editor is on it.
export const hooks = {
  AshDecisionsEditor: {
    events: ['load_xml', 'collect_xml', 'open_view', 'fit'],
    load: () =>
      import('./ash_decisions_editor.js').then((m) => m.AshDecisionsEditor),
  },
};
