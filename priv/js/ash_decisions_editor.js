/**
 * SPDX-FileCopyrightText: 2026 Luke Galea
 * SPDX-License-Identifier: MIT
 *
 * ash_decisions DMN editor Phoenix LiveView hook.
 *
 * IMPORTANT: The bpmn.io watermark (".bjs-powered-by") must NEVER be removed,
 * hidden, or obscured. dmn-js ships under the same licence text as bpmn-js --
 * byte-for-byte identical, watermark clause included -- so the obligation is the
 * same here as it is in the process designer, and it constrains two things that
 * are easy to forget: CSS that collapses the element, and screenshot cropping
 * that cuts it off.
 */

import Modeler from 'dmn-js/lib/Modeler';

import 'dmn-js/dist/assets/diagram-js.css';
import 'dmn-js/dist/assets/dmn-js-shared.css';
import 'dmn-js/dist/assets/dmn-js-drd.css';
import 'dmn-js/dist/assets/dmn-js-decision-table.css';
import 'dmn-js/dist/assets/dmn-js-decision-table-controls.css';
import 'dmn-js/dist/assets/dmn-js-literal-expression.css';
import 'dmn-js/dist/assets/dmn-font/css/dmn-embedded.css';

import './ash_decisions.css';

// ---------------------------------------------------------------------------
// A DMN document is not one diagram. dmn-js models it as a *list of views*: one
// `drd` view for the decision requirements diagram, plus one view per decision
// for its boxed expression -- `decisionTable` or `literalExpression` depending
// on what the decision actually holds.
//
// dmn-js deliberately ships no view switcher; every dmn-js example builds its
// own. So the tabs are rendered server-side by the LiveView from the view list
// this hook pushes up, and switching is a round trip. That is the right side to
// put them on: the tab strip then styles like the rest of the application
// instead of like a second design system embedded in one page.
//
// The provider ids are dmn-js's own, read out of the bundle rather than assumed:
// 'drd', 'decisionTable', 'literalExpression', 'boxedExpression'.
// ---------------------------------------------------------------------------

const VIEW_LABELS = {
  drd: 'Requirements',
  decisionTable: 'Decision table',
  literalExpression: 'Literal expression',
  boxedExpression: 'Boxed expression'
};

function viewLabel(view) {
  return VIEW_LABELS[view.type] || view.type;
}

// A view's element is a moddle object: the Definitions for the DRD, the
// Decision for everything else. Its name is what a person recognises; the id is
// what survives a rename, so the tab needs both.
function describeView(view, index) {
  const element = view.element || {};

  return {
    index: index,
    type: view.type,
    label: viewLabel(view),
    name: element.name || '',
    element_id: element.id || ''
  };
}

function pushError(hook, err) {
  const message = err && err.message ? err.message : String(err);
  hook.pushEvent('import_error', { message: message });
}

function resolveContainer(el) {
  return el.querySelector('.ash-decisions-canvas') || el;
}

// ---------------------------------------------------------------------------
// AshDecisionsEditor -- Phoenix LiveView hook (plain object, NOT a class)
//
// Hook -> LV  (pushEvent):
//   save_xml      %{ xml: string }
//   views_changed %{ views: [view], active: integer | nil }
//   dirty_changed %{ dirty: boolean }
//   import_error  %{ message: string }
//
// LV -> Hook  (handleEvent):
//   load_xml    %{ xml }
//   collect_xml %{}
//   open_view   %{ index }
//   fit         %{}
// ---------------------------------------------------------------------------

export const AshDecisionsEditor = {
  mounted() {
    const container = resolveContainer(this.el);

    if (!container) {
      pushError(this, 'AshDecisionsEditor: no .ash-decisions-canvas container found');
      return;
    }

    try {
      this._modeler = new Modeler({ container: container });
    } catch (err) {
      pushError(this, err);
      return;
    }

    // Every view is a separate viewer with its own command stack, created lazily
    // the first time that view is opened. So dirty tracking cannot be attached
    // once at mount: it has to be attached as each viewer comes into existence,
    // or editing a decision table after opening the DRD leaves the Save button
    // disabled over unsaved changes.
    //
    // Bound viewers are remembered because 'viewer.created' fires per viewer but
    // a viewer can be handed back to us again; binding twice would double every
    // dirty event.
    this._boundViewers = new Set();

    this._modeler.on('viewer.created', ({ viewer }) => {
      if (!viewer || this._boundViewers.has(viewer)) return;

      this._boundViewers.add(viewer);

      try {
        viewer.get('eventBus').on('commandStack.changed', () => {
          this.pushEvent('dirty_changed', { dirty: true });
        });
      } catch (err) {
        // A viewer without a command stack is read-only, not broken.
      }
    });

    this._modeler.on('views.changed', ({ views, activeView }) => {
      const described = views.map(describeView);
      const active = activeView ? views.indexOf(activeView) : null;

      this.pushEvent('views_changed', {
        views: described,
        active: active === -1 ? null : active
      });
    });

    this._importXml(this.el.dataset.xml || '', { resetDirty: false });

    this.handleEvent('load_xml', (payload) => {
      this._importXml(payload.xml, { resetDirty: true });
    });

    this.handleEvent('collect_xml', () => {
      this._modeler
        .saveXML({ format: true })
        .then((result) => this.pushEvent('save_xml', { xml: result.xml }))
        .catch((err) => pushError(this, err));
    });

    this.handleEvent('open_view', (payload) => {
      const views = this._modeler.getViews();
      const view = views[payload.index];

      if (!view) {
        pushError(this, 'open_view: no view at index ' + payload.index);
        return;
      }

      this._modeler.open(view).catch((err) => pushError(this, err));
    });

    this.handleEvent('fit', () => this._fit());
  },

  destroyed() {
    if (this._modeler) {
      this._modeler.destroy();
      this._modeler = null;
    }
    this._boundViewers = null;
  },

  _importXml(xml, opts) {
    if (!xml) return;

    this._modeler
      .importXML(xml)
      .then(() => {
        this._fit();
        if (opts.resetDirty) this.pushEvent('dirty_changed', { dirty: false });
      })
      .catch((err) => pushError(this, err));
  },

  // Only the DRD has a canvas to zoom. A decision table is a table: asking it
  // for a canvas throws, and the throw would otherwise surface as an import
  // error on a document that imported perfectly well.
  _fit() {
    try {
      const viewer = this._modeler.getActiveViewer();
      const active = this._modeler.getActiveView();

      if (viewer && active && active.type === 'drd') {
        viewer.get('canvas').zoom('fit-viewport', 'auto');
      }
    } catch (err) {
      // Nothing to fit is not a failure.
    }
  }
};
