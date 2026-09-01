/* Shared dependency-free SVG mapping for the dashboard and tracking page. */

(function () {
  const WIDTH = 1000;
  const HEIGHT = 500;
  const LAND = `
    <image class="map-land" href="/static/world-land.svg" x="0" y="0" width="${WIDTH}" height="${HEIGHT}"
           preserveAspectRatio="none" aria-hidden="true"/>`;

  function escape(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, (ch) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[ch]));
  }

  function project(point) {
    return {
      x: ((Number(point.longitude) + 180) / 360) * WIDTH,
      y: ((90 - Number(point.latitude)) / 180) * HEIGHT,
    };
  }

  function arcPath(left, right, lift = 0.22) {
    const a = project(left);
    const b = project(right);
    const distance = Math.abs(b.x - a.x);
    const controlX = (a.x + b.x) / 2;
    const controlY = Math.max(24, Math.min(a.y, b.y) - Math.max(28, distance * lift));
    return `M ${a.x.toFixed(1)} ${a.y.toFixed(1)} Q ${controlX.toFixed(1)} ${controlY.toFixed(1)} ${b.x.toFixed(1)} ${b.y.toFixed(1)}`;
  }

  function definitions() {
    return `
      <defs>
        <filter id="map-glow"><feGaussianBlur stdDeviation="4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
        <marker id="route-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M0 0 10 5 0 10Z"/>
        </marker>
      </defs>`;
  }

  function renderRoute(svg, points, progressPercent) {
    if (!svg) return;
    if (!Array.isArray(points) || points.length < 2) {
      svg.innerHTML = `${definitions()}${LAND}<text x="500" y="260" text-anchor="middle" class="map-empty">Route map appears after geocoding</text>`;
      return;
    }

    const progress = Number(progressPercent) || 0;
    const segments = points.slice(0, -1).map((point, index) => {
      const completeAt = 40 + index * 20;
      const activeAt = Math.max(20, completeAt - 20);
      const state = progress >= completeAt ? "complete" : progress >= activeAt ? "active" : "pending";
      return `<path class="route-segment ${state}" d="${arcPath(point, points[index + 1])}" marker-end="url(#route-arrow)"/>`;
    }).join("");

    const positions = points.map(project);
    const markers = points.map((point, index) => {
      const position = positions[index];
      const reachedAt = index === 0 ? 20 : 20 + index * 20;
      const state = progress >= reachedAt ? "reached" : "pending";
      const endpoint = point.kind === "origin" || point.kind === "destination" ? " endpoint" : "";
      const overlapsEarlierLabel = positions.slice(0, index).some((earlier) =>
        Math.abs(position.x - earlier.x) < 90 && Math.abs(position.y - earlier.y) < 35
      );
      const labelY = overlapsEarlierLabel ? 30 : -16;
      return `
        <g class="route-marker ${state}${endpoint}" transform="translate(${position.x.toFixed(1)} ${position.y.toFixed(1)})">
          <circle r="${endpoint ? 10 : 7}"/>
          <text y="${labelY}" text-anchor="middle">${escape(point.location)}</text>
        </g>`;
    }).join("");

    const delivered = progress >= 100
      ? `<g class="delivered-stamp" transform="translate(815 420) rotate(-7)"><rect width="150" height="48" rx="4"/><text x="75" y="32" text-anchor="middle">DELIVERED</text></g>`
      : "";
    svg.innerHTML = `${definitions()}${LAND}<g class="route-lines">${segments}</g>${markers}${delivered}`;
  }

  function renderGlobe(svg, shipments) {
    if (!svg) return;
    const routes = (shipments || []).filter((shipment) =>
      Array.isArray(shipment.route_points) && shipment.route_points.length >= 2
    );
    const arcs = routes.map((shipment, index) => {
      const origin = shipment.route_points[0];
      const destination = shipment.route_points[shipment.route_points.length - 1];
      const classes = [
        "audience-arc",
        shipment.is_golden ? "golden" : "",
        shipment.status === "DELIVERED" ? "delivered" : "active",
      ].filter(Boolean).join(" ");
      return `
        <path class="${classes}" style="--arc-delay:${(index % 12) * -0.35}s" d="${arcPath(origin, destination, 0.16)}">
          <title>${escape(shipment.tracking_number)}: ${escape(shipment.origin)} to ${escape(shipment.destination)}</title>
        </path>`;
    }).join("");
    const points = routes.flatMap((shipment) => {
      const origin = project(shipment.route_points[0]);
      const destination = project(shipment.route_points[shipment.route_points.length - 1]);
      return [
        `<circle class="audience-point" cx="${origin.x.toFixed(1)}" cy="${origin.y.toFixed(1)}" r="3"/>`,
        `<circle class="audience-point destination" cx="${destination.x.toFixed(1)}" cy="${destination.y.toFixed(1)}" r="4"/>`,
      ];
    }).join("");
    const empty = routes.length
      ? ""
      : `<text x="500" y="260" text-anchor="middle" class="map-empty">Audience routes will appear here</text>`;
    svg.innerHTML = `${definitions()}${LAND}<g class="audience-routes">${arcs}</g>${points}${empty}`;
  }

  window.ZavaMap = { renderRoute, renderGlobe };
})();
