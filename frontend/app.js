const $ = s => document.querySelector(s);
const fmt = v => Number(v).toFixed(2);
const sum = (rows, f) => rows.reduce((a, r) => a + Number(r[f]), 0);

async function api(url, method = 'GET', body) {
  const r = await fetch(url, {
    method, headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined
  });
  if (!r.ok) throw new Error(await r.text());
  return r.status === 204 ? null : r.json();
}

document.querySelectorAll('.tab').forEach(b => b.onclick = () => {
  document.querySelectorAll('.tab').forEach(x => x.classList.remove('active'));
  document.querySelectorAll('.page').forEach(x => x.classList.remove('active'));
  b.classList.add('active'); $('#tab-' + b.dataset.tab).classList.add('active');
});

const CRUD = {
  saldo: {
    url: '/api/saldo',
    head: ['Счет', 'Конец периода', 'Сальдо (исх.)', 'Входящее?', ''],
    view: r => [r.account_number, r.period_date, fmt(r.amount), r.is_base ? 'да' : '—'],
    load: (f, r) => { f.account_number.value = r.account_number; f.period_date.value = r.period_date; f.amount.value = r.amount; f.is_base.checked = r.is_base; },
    data: f => ({ account_number: f.account_number.value, period_date: f.period_date.value, amount: f.amount.value, is_base: f.is_base.checked })
  },
  charges: {
    url: '/api/charges',
    head: ['Счет', 'Услуга', 'Дата и время', 'Сумма', ''],
    view: r => [r.account_number, r.service_type || '', String(r.charge_date).replace('T', ' '), fmt(r.amount)],
    load: (f, r) => { f.account_number.value = r.account_number; f.service_type.value = r.service_type || ''; f.charge_date.value = String(r.charge_date).replace(' ', 'T'); f.amount.value = r.amount; },
    data: f => ({ account_number: f.account_number.value, service_type: f.service_type.value || null, charge_date: f.charge_date.value, amount: f.amount.value })
  },
  payments: {
    url: '/api/payments',
    head: ['Счет', 'Дата и время платежа', 'Сумма', 'Способ', ''],
    view: r => [r.account_number, String(r.payment_date).replace('T', ' '), fmt(r.amount), r.payment_method || ''],
    load: (f, r) => { f.account_number.value = r.account_number; f.payment_date.value = String(r.payment_date).replace(' ', 'T'); f.amount.value = r.amount; f.payment_method.value = r.payment_method || ''; },
    data: f => ({ account_number: f.account_number.value, payment_date: f.payment_date.value, amount: f.amount.value, payment_method: f.payment_method.value || null })
  }
};
const editing = { saldo: null, charges: null, payments: null };

async function refresh(entity) {
  const c = CRUD[entity];
  try {
    const rows = await api(c.url);
    let html = '<table><tr>' + c.head.map(h => `<th>${h}</th>`).join('') + '</tr>';
    for (const r of rows) {
      html += `<tr>${c.view(r).map(v => `<td>${v}</td>`).join('')}
        <td class="acts">
          <button data-edit="${r.id}">✎</button>
          <button data-del="${r.id}">✕</button>
        </td></tr>`;
    }
    $('#grid-' + entity).innerHTML = html + '</table>';
    $('#grid-' + entity).querySelectorAll('[data-edit]').forEach(b => b.onclick = () => {
      editing[entity] = +b.dataset.edit;
      c.load($('#form-' + entity), rows.find(x => x.id === +b.dataset.edit));
      $('#form-' + entity).querySelector('.cancel').hidden = false;
    });
    $('#grid-' + entity).querySelectorAll('[data-del]').forEach(b => b.onclick = async () => {
      if (!confirm('Удалить запись?')) return;
      await api(c.url + '/' + b.dataset.del, 'DELETE');
      refresh(entity); refreshAccounts();
    });
  } catch (err) {
    $('#grid-' + entity).innerHTML = `<p style="color:red;">Ошибка: ${err.message}</p>`;
  }
}

for (const entity of Object.keys(CRUD)) {
  const form = $('#form-' + entity);
  form.onsubmit = async e => {
    e.preventDefault();
    const c = CRUD[entity];
    try {
      if (editing[entity]) await api(c.url + '/' + editing[entity], 'PUT', c.data(form));
      else await api(c.url, 'POST', c.data(form));
      form.reset(); editing[entity] = null; form.querySelector('.cancel').hidden = true;
      refresh(entity); refreshAccounts();
    } catch (err) { alert(err.message); }
  };
  form.querySelector('.cancel').onclick = () => { form.reset(); editing[entity] = null; form.querySelector('.cancel').hidden = true; };
  refresh(entity);
}

async function refreshAccounts() {
  try {
    const rows = await api('/api/saldo');
    const accs = [...new Set(rows.map(r => r.account_number))];
    $('#rep2-acc').innerHTML = accs.map(a => `<option>${a}</option>`).join('');
  } catch(e){}
}
refreshAccounts();

// Заголовки месяцев: только 12 уникальных (01..12)
function monthHeaders(rows) {
  const seen = new Set();
  const months = [];
  for (const r of rows) {
    if (!r.month_start) continue;
    const mm = r.month_start.slice(5, 7);
    if (!seen.has(mm)) { seen.add(mm); months.push(mm); }
    if (months.length >= 12) break;
  }
  return months;
}

// ===== ОТЧЕТ 1: оборотная ведомость (все квартиры) =====
// 4 строки на квартиру: Вх.сальдо / Начис. / Опл. / Исх.сальдо
$('#rep1-btn').onclick = async () => {
  try {
    const rows = await api('/api/reports/turnover?year=' + $('#rep1-year').value);
    const accs = [...new Set(rows.map(r => r.account_number))];
    const months = monthHeaders(rows);

    let html = '<table class="rep"><tr><th rowspan="2">Кв.</th><th rowspan="2"></th>';
    html += months.map(m => `<th>${m}</th>`).join('');
    html += '<th rowspan="2">Итого</th></tr><tr></tr>';

    for (const a of accs) {
      const m = rows.filter(r => r.account_number === a);
      const totalCharge  = sum(m, 'charge_sum');
      const totalPayment = sum(m, 'payment_sum');
      const finalSaldo   = m.length ? m[m.length - 1].saldo_close : 0;

      html += '<tr>';
      html += `<td rowspan="4"><b>${a}</b></td>`;
      html += '<td>Вх. сальдо</td>';
      html += m.map(r => `<td>${fmt(r.saldo_open)}</td>`).join('');
      html += '<td></td></tr>';

      html += '<tr><td>Начис.</td>';
      html += m.map(r => `<td>${fmt(r.charge_sum)}</td>`).join('');
      html += `<td><b>${fmt(totalCharge)}</b></td></tr>`;

      html += '<tr><td>Опл.</td>';
      html += m.map(r => `<td>${fmt(r.payment_sum)}</td>`).join('');
      html += `<td><b>${fmt(totalPayment)}</b></td></tr>`;

      html += '<tr><td>Исх. сальдо</td>';
      html += m.map(r => `<td>${fmt(r.saldo_close)}</td>`).join('');
      html += `<td><b>${fmt(finalSaldo)}</b></td></tr>`;
    }
    $('#rep1-out').innerHTML = html + '</table>';
  } catch(e) { $('#rep1-out').innerHTML = '<p style="color:red">'+e.message+'</p>'; }
};

// ===== ОТЧЕТ 2: оборотная ведомость по квартире =====
$('#rep2-btn').onclick = async () => {
  try {
    const acc = $('#rep2-acc').value;
    const rows = await api(`/api/reports/turnover/${acc}?from=${$('#rep2-from').value}&to=${$('#rep2-to').value}`);
    const m = rows.filter(r => r.month_start);
    const t = rows.find(r => !r.month_start);
    const months = monthHeaders(m);

    let html = '<table class="rep"><tr><th rowspan="2"></th>';
    html += months.map(mm => `<th>${mm}</th>`).join('');
    html += '<th rowspan="2">Итого</th></tr><tr></tr>';

    html += '<tr><td>Вх. сальдо</td>';
    html += m.map(r => `<td>${fmt(r.saldo_open)}</td>`).join('');
    html += `<td><b>${fmt(t ? t.saldo_open : 0)}</b></td></tr>`;

    html += '<tr><td>Начис.</td>';
    html += m.map(r => `<td>${fmt(r.charge_sum)}</td>`).join('');
    html += `<td><b>${fmt(t ? t.charge_sum : 0)}</b></td></tr>`;

    html += '<tr><td>Опл.</td>';
    html += m.map(r => `<td>${fmt(r.payment_sum)}</td>`).join('');
    html += `<td><b>${fmt(t ? t.payment_sum : 0)}</b></td></tr>`;

    html += '<tr><td>Исх. сальдо</td>';
    html += m.map(r => `<td>${fmt(r.saldo_close)}</td>`).join('');
    html += `<td><b>${fmt(t ? t.saldo_close : 0)}</b></td></tr>`;

    html += `<tr><td colspan="${months.length + 2}"><b>Итого к оплате на конец периода: ${fmt(t ? t.saldo_close : 0)}</b></td></tr>`;
    $('#rep2-out').innerHTML = html + '</table>';
  } catch(e) { $('#rep2-out').innerHTML = '<p style="color:red">'+e.message+'</p>'; }
};

// ===== ОТЧЕТ 3: сводка по должникам =====
$('#rep3-btn').onclick = async () => {
  try {
    const rows = await api('/api/reports/debtors?as_of=' + $('#rep3-asof').value);
    let html = '<table class="rep"><tr>';
    html += '<th rowspan="2">Квартира</th>';
    html += '<th rowspan="2">Начислено (посл. мес.)</th>';
    html += '<th rowspan="2">Сальдо</th>';
    html += '<th colspan="4">Категории долга</th></tr>';
    html += '<tr><th>1 мес</th><th>2 мес</th><th>3 мес</th><th>свыше 3</th></tr>';
    for (const r of rows) {
      html += `<tr>
        <td>${r.account_number}</td>
        <td>${fmt(r.last_charge)}</td>
        <td>${fmt(r.saldo_debt)}</td>
        <td>${r.debt_1 > 0 ? fmt(r.debt_1) : '—'}</td>
        <td>${r.debt_2 > 0 ? fmt(r.debt_2) : '—'}</td>
        <td>${r.debt_3 > 0 ? fmt(r.debt_3) : '—'}</td>
        <td>${r.debt_over3 > 0 ? fmt(r.debt_over3) : '—'}</td>
      </tr>`;
    }
    $('#rep3-out').innerHTML = html + '</table>';
  } catch(e) { $('#rep3-out').innerHTML = '<p style="color:red">'+e.message+'</p>'; }
};
