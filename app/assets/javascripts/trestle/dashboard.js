document.addEventListener('DOMContentLoaded', function() {
  const dashboard = document.querySelector('.dashboard-container');
  if (!dashboard) return;

  const refreshBtn = document.getElementById('refresh-btn');
  const statsFields = document.querySelectorAll('.stat-value[data-field]');
  const chartContainer = document.getElementById('orders-chart');
  const topProductsList = document.querySelector('.top-products-list');
  const ordersList = document.querySelector('.orders-list');
  const progressList = document.querySelector('.progress-list');

  function updateDashboard() {
    refreshBtn.classList.add('loading');
    refreshBtn.disabled = true;

    fetch('/trestle/dashboard/stats')
      .then(response => response.json())
      .then(data => {
        // Update stats
        statsFields.forEach(field => {
          const key = field.dataset.field;
          if (data[key] !== undefined) {
            if (['revenue', 'avg_check'].includes(key)) {
              field.textContent = new Intl.NumberFormat('ru-RU', {
                style: 'currency',
                currency: 'BYN'
              }).format(data[key]);
            } else {
              field.textContent = data[key];
            }
          }
        });

        // Update Chart
        if (data.chart_data && chartContainer) {
          const maxCount = Math.max(...data.chart_data.map(d => d.count), 1);
          chartContainer.innerHTML = data.chart_data.map(day => {
            const height = (day.count / maxCount) * 100;
            return `
              <div class="chart-bar" style="height: ${height}%" data-value="${day.count}">
                <div class="bar-tooltip">${day.date}: ${day.count}</div>
              </div>
            `;
          }).join('');
        }

        // Update Top Products
        if (data.top_products && topProductsList) {
          topProductsList.innerHTML = data.top_products.map((p, i) => `
            <div class="product-item">
              <div class="product-rank">${i + 1}</div>
              <div class="product-details">
                <span class="product-name">${p.name}</span>
                <span class="product-sku">${p.sku}</span>
              </div>
              <div class="product-views">
                <span class="views-count">${p.views}</span>
                <span class="views-label">просмотров</span>
              </div>
            </div>
          `).join('');
        }

        // Update Recent Orders
        if (data.recent_orders && ordersList) {
          ordersList.innerHTML = data.recent_orders.map(o => `
            <div class="order-item">
              <div class="order-status-dot status-${o.status}"></div>
              <div class="order-details">
                <span class="order-customer">${o.customer}</span>
                <span class="order-time">${new Date(o.created_at).toLocaleDateString()}</span>
              </div>
              <div class="order-total">${new Intl.NumberFormat('ru-RU', {
                style: 'currency',
                currency: 'BYN'
              }).format(o.total)}</div>
            </div>
          `).join('');
        }

        // Update Progress
        if (data.progress && progressList) {
          const labels = {
            catalog: 'Заполненность каталога',
            orders: 'Обработка заказов',
            reviews: 'Ответы на отзывы'
          };
          progressList.innerHTML = Object.entries(data.progress).map(([key, value]) => `
            <div class="progress-item">
              <div class="progress-info">
                <span class="progress-label">${labels[key]}</span>
                <span class="progress-value">${value}%</span>
              </div>
              <div class="progress-track">
                <div class="progress-fill" style="width: ${value}%"></div>
              </div>
            </div>
          `).join('');
        }
      })
      .catch(error => console.error('Dashboard update failed:', error))
      .finally(() => {
        refreshBtn.classList.remove('loading');
        refreshBtn.disabled = false;
      });
  }

  // Refresh button click
  refreshBtn.addEventListener('click', updateDashboard);

  // Auto-polling every 30 seconds
  const pollingInterval = setInterval(updateDashboard, 30000);

  // Clear interval on page navigation (if Trestle uses Turbolinks/Turbo)
  document.addEventListener('turbo:before-cache', () => {
    clearInterval(pollingInterval);
  });
});
