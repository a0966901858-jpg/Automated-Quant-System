% =========================================================================
% 自動化總經與量化交易日報系統 (Automated_Macro_Quant_System.m)
% 全球宏觀升級版：16大指數/商品 + 約翰森共整合檢定 + 近20日趨勢 AI 判讀
% =========================================================================

function Automated_Macro_Quant_System()
    try
        clc; clear; close all;
        fprintf('[%s] 系統啟動，開始執行每日量化與總經資料更新...\n', datestr(now));
        
        %% 參數設定區
        gemini_api_keys = {
            getenv('GEMINI_API_KEY_1'), getenv('GEMINI_API_KEY_2'), ...
            getenv('GEMINI_API_KEY_3'), getenv('GEMINI_API_KEY_4'), ...
            getenv('GEMINI_API_KEY_5'), getenv('GEMINI_API_KEY_6'), ...
            getenv('GEMINI_API_KEY_7'), getenv('GEMINI_API_KEY_8'), ...
            getenv('GEMINI_API_KEY_9'), getenv('GEMINI_API_KEY_10')
        }; 
        
        gemini_api_keys = gemini_api_keys(~cellfun(@isempty, gemini_api_keys));
        if isempty(gemini_api_keys)
            error('未偵測到任何 Gemini API Key，請檢查 GitHub Secrets 設定。');
        end
        
        sender_email = getenv('GMAIL_SENDER');      
        sender_pwd = getenv('GMAIL_PWD');           
        receiver_email = getenv('GMAIL_RECEIVER');  
        
        %% Phase 1: 爬取全球宏觀市場數據 (包含歐亞美大盤)
        fprintf('正在爬取全球總經與市場數據...\n');
        
        % 納入日(N225), 韓(KS11), 中(000001.SS), 港(HSI), 德(GDAXI), 法(FCHI)
        tickers = {'^TWII', '^GSPC', '^IXIC', '^DJI', '^SOX', '^N225', '^KS11', '000001.SS', '^HSI', '^GDAXI', '^FCHI', 'GC=F', 'BTC-USD', 'CL=F', '^TNX', '^VIX'};
        field_keys = {'TWII', 'SP500', 'NASDAQ', 'DJI', 'SOX', 'N225', 'KOSPI', 'SSEC', 'HSI', 'DAX', 'CAC40', 'Gold', 'BTC', 'Oil', 'US10Y', 'VIX'}; 
        names = {'台股加權', '標普500', '納斯達克', '道瓊工業', '費城半導體', '日經225', '韓國KOSPI', '上證指數', '恆生指數', '德國DAX', '法國CAC40', '黃金價格', '比特幣', '國際原油', '美10Y公債', '標普VIX'};
        
        market_data = struct();
        start_dt = datetime('today', 'TimeZone', 'local') - calmonths(6); 
        trend_block = ""; % 用於提供給 LLM 的 20 日趨勢字串
        
        for i = 1:length(tickers)
            [~, prices, last_price] = fetch_yahoo_data(tickers{i}, start_dt);
            
            % 計算當日漲跌幅 (%)
            if length(prices) >= 2
                change_pct = ((prices(end) - prices(end-1)) / prices(end-1)) * 100;
            else
                change_pct = 0;
            end
            
            % 擷取近 20 日價格趨勢 (提供給 LLM 判讀)
            if length(prices) >= 20
                prices_20d = prices(end-19:end);
            else
                prices_20d = prices;
            end
            trend_str = sprintf('%.2f, ', prices_20d);
            trend_str = trend_str(1:end-2); % 移除最後的逗號
            
            market_data.(field_keys{i}) = struct('Prices', prices, 'Last', last_price, 'ChangePct', change_pct, 'Trend20d', trend_str);
            fprintf(' - %s 更新完成 (最新: %.2f, 漲跌幅: %+.2f%%)\n', names{i}, last_price, change_pct);
            
            % 疊加字串給 LLM
            trend_block = trend_block + string(names{i}) + " 近20日價格: [" + string(trend_str) + "]" + char(10);
        end
        
        %% Phase 2: 約翰森共整合檢定 (Johansen Test) 與 Z-Score 機率分析
        fprintf('進行約翰森共整合檢定 (S&P 500 vs 台股)...\n');
        
        p_sp500 = market_data.SP500.Prices;
        p_twii = market_data.TWII.Prices;
        
        min_len = min(length(p_sp500), length(p_twii));
        p_sp500 = p_sp500(end-min_len+1:end);
        p_twii = p_twii(end-min_len+1:end);
        
        Y = [log(p_sp500), log(p_twii)];
        
        try
            % 執行約翰森檢定
            [~,~,~,~,mles] = jcitest(Y, 'Display', 'off');
            % 提取第一組共整合向量 (Cointegrating Vector)
            cv = mles(2).EVec(:,1);
            % 正規化：以台股係數作為基準
            cv = cv / cv(2); 
            spread = Y * cv;
        catch ME
            fprintf('約翰森檢定失敗，降級使用 OLS 回歸: %s\n', ME.message);
            c = cov(Y(:,1), Y(:,2));
            beta = c(1,2) / c(1,1);
            spread = Y(:,2) - beta * Y(:,1);
        end
        
        % 計算 Z-Score
        z_score = (spread(end) - mean(spread)) / std(spread);
        
        % === 均值回歸機率計算 ===
        % 利用常態分佈累積函數 (CDF) 將 Z-Score 轉化為發生極端偏差的「異常機率」，
        % 偏差越極端，向均值回歸的力量與機率就越高。
        reversion_prob = (normcdf(abs(z_score)) - normcdf(-abs(z_score))) * 100;
        
        if z_score > 0
            direction_str = sprintf('台股相對美股溢價 (向下收斂機率: %.2f%%)', reversion_prob);
        else
            direction_str = sprintf('台股相對美股折價 (向上收斂機率: %.2f%%)', reversion_prob);
        end
        
        %% Phase 3: 建立「程式驅動表頭」與呼叫 Gemini API
        fprintf('正在呼叫 Gemini API 進行資訊整合...\n');
        
        market_header = sprintf([...
            '========================================================\n', ...
            '📊【程式自動追蹤 - 全球宏觀市場與風險指標】\n', ...
            '========================================================\n', ...
            '標普 VIX : %8.2f (%+.2f%%)\n', ...
            '台股加權 : %8.2f (%+.2f%%)\n', ...
            '標普 500 : %8.2f (%+.2f%%)\n', ...
            '納斯達克 : %8.2f (%+.2f%%)\n', ...
            '道瓊工業 : %8.2f (%+.2f%%)\n', ...
            '費城半導 : %8.2f (%+.2f%%)\n', ...
            '日經 225 : %8.2f (%+.2f%%)\n', ...
            '韓國KOSPI: %8.2f (%+.2f%%)\n', ...
            '上證指數 : %8.2f (%+.2f%%)\n', ...
            '恆生指數 : %8.2f (%+.2f%%)\n', ...
            '德國 DAX : %8.2f (%+.2f%%)\n', ...
            '法國CAC40: %8.2f (%+.2f%%)\n', ...
            '美10Y公債: %8.2f (%+.2f%%)\n', ...
            '比 特 幣 : %8.2f (%+.2f%%)\n', ...
            '黃金價格 : %8.2f (%+.2f%%)\n', ...
            '國際原油 : %8.2f (%+.2f%%)\n', ...
            '--------------------------------------------------------\n', ...
            '【約翰森檢定配對 (S&P 500 vs 台股)】\n', ...
            '價差 Z-Score: %+.2f | 狀態: %s\n', ...
            '========================================================\n\n'], ...
            market_data.VIX.Last, market_data.VIX.ChangePct, ...
            market_data.TWII.Last, market_data.TWII.ChangePct, ...
            market_data.SP500.Last, market_data.SP500.ChangePct, ...
            market_data.NASDAQ.Last, market_data.NASDAQ.ChangePct, ...
            market_data.DJI.Last, market_data.DJI.ChangePct, ...
            market_data.SOX.Last, market_data.SOX.ChangePct, ...
            market_data.N225.Last, market_data.N225.ChangePct, ...
            market_data.KOSPI.Last, market_data.KOSPI.ChangePct, ...
            market_data.SSEC.Last, market_data.SSEC.ChangePct, ...
            market_data.HSI.Last, market_data.HSI.ChangePct, ...
            market_data.DAX.Last, market_data.DAX.ChangePct, ...
            market_data.CAC40.Last, market_data.CAC40.ChangePct, ...
            market_data.US10Y.Last, market_data.US10Y.ChangePct, ...
            market_data.BTC.Last, market_data.BTC.ChangePct, ...
            market_data.Gold.Last, market_data.Gold.ChangePct, ...
            market_data.Oil.Last, market_data.Oil.ChangePct, ...
            z_score, direction_str);

        % 餵給 AI 的 Prompt (要求查詢新聞並分析 20日趨勢)
        prompt = sprintf([...
            '你是一位專業且具備宏觀避險基金視角的財經晨報編輯。請根據以下最新數據與近20日趨勢，產出一份「極簡、一分鐘完讀」的快訊版晨報，直接給結論。**請務必使用 Markdown 格式進行排版。**\n\n', ...
            '### 📊 各標的近 20 日價格走勢\n%s\n', ...
            '### 🧮 約翰森共整合檢定 (S&P 500 vs 台股)\n', ...
            '* **當前 Z-Score:** %+.2f\n', ...
            '* **統計回歸分析:** %s\n\n', ...
            '### 📌 任務要求（請嚴格遵守）\n', ...
            '1. **【時事頭條】**：請主動查詢網路上「今日全球查詢率最高的三大國際財經新聞」，並使用 Markdown 條列式列為報告開頭。\n', ...
            '2. **【市場速讀】**：綜合上述 20 日趨勢數據，用一句話總結今日全球（歐、美、亞）市場的主旋律與資金流向，並將**關鍵字加上粗體**。\n', ...
            '3. **【資金前瞻】**：根據「美債殖利率」與「大宗商品」的走勢變化，指出對全球股市板塊的潛在資金推力或壓力。\n', ...
            '4. **【量化定調】**：根據 Z-Score 的正負值與回歸機率數值，給出明確的台股與美股間的「套利或避險」操作提示。\n', ...
            '5. **【格式限制】**：總字數嚴格控制在 350 字內。全程使用 Markdown 語法（包含 `##` 主標題、`###` 副標題、`-` 條列式、`**` 粗體強調重點）。\n', ...
            '6. **【重要排版】**：絕對不要在報告中重複列出詳細報價與數據數值，請直接給出你的洞察與分析結論。'], ...
            trend_block, z_score, direction_str);
            
        report_content = call_gemini_api_with_rotation(prompt, gemini_api_keys);
        fprintf('\n=== Gemini 報告生成成功 ===\n');
        
        %% Phase 4: 組合並發送 Gmail
        report_str = strjoin(string(report_content), char(10));
        final_report = char(string(market_header) + report_str);
        
        fprintf('正在透過 Gmail 發送日報...\n');
        send_report_to_gmail(sender_email, sender_pwd, receiver_email, final_report);
        
        fprintf('[%s] 系統全部執行完畢！\n', datestr(now));
        
    catch ME
        fprintf('系統執行發生嚴重錯誤: %s\n', ME.message);
    end
end

% =========================================================================
% 輔助函數 (Helper Functions)
% =========================================================================

% 1. Yahoo Finance 歷史資料爬蟲
function [timestamps, prices, last_price] = fetch_yahoo_data(ticker, start_dt)
    t_now = datetime('now', 'TimeZone', 'local');
    period2 = num2str(round(posixtime(t_now)));
    
    if isempty(start_dt.TimeZone)
        start_dt.TimeZone = 'local';
    end
    period1 = num2str(round(posixtime(start_dt)));
    
    url = sprintf('https://query2.finance.yahoo.com/v8/finance/chart/%s?period1=%s&period2=%s&interval=1d', ticker, period1, period2);
    options = weboptions('UserAgent', 'Mozilla/5.0', 'Timeout', 20);
    
    try
        data = webread(url, options);
        if iscell(data.chart.result)
            res = data.chart.result{1};
        else
            res = data.chart.result(1);
        end
        timestamps = double(res.timestamp(:));
        prices = double(res.indicators.quote(1).close(:)); 
        
        valid_idx = ~isnan(prices);
        timestamps = timestamps(valid_idx);
        prices = prices(valid_idx);
        last_price = prices(end);
    catch
        timestamps = []; prices = []; last_price = NaN;
    end
end

% 2. 多金鑰輪替與防封鎖呼叫機制 (Gemini API)
function report_text = call_gemini_api_with_rotation(prompt, api_keys)
    maxRetries = 9; 
    attempt = 0; 
    success = false; 
    currentKeyIdx = 1; 
    report_text = '';
    
    while attempt < maxRetries && ~success 
        attempt = attempt + 1; 
        
        if attempt > 1 
            cooldown = attempt * 2; 
            fprintf('冷卻 %d 秒後進行第 %d 次重試...\n', cooldown, attempt); 
            pause(cooldown); 
            
            currentKeyIdx = mod(currentKeyIdx, length(api_keys)) + 1; 
            fprintf('已切換至備用金鑰 (Index: %d)，重新分析中...\n', currentKeyIdx);
        end
        
        current_key = api_keys{currentKeyIdx}; 
        url = sprintf('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=%s', current_key); 
        payload = struct('contents', struct('parts', struct('text', prompt))); 
        options = weboptions('MediaType', 'application/json', 'Timeout', 45, 'RequestMethod', 'post'); 
        
        try
            res = webwrite(url, payload, options); 
            report_text = res.candidates(1).content.parts(1).text; 
            success = true; 
        catch ME
            fprintf('❌ 呼叫失敗 (嘗試 %d/%d)！錯誤訊息: %s\n', attempt, maxRetries, ME.message);
            if attempt >= maxRetries 
                report_text = sprintf('分析失敗。已達最大重試次數 (%d)。錯誤原因: %s', maxRetries, ME.message); 
            end
        end
    end
end
% 3. 寄送 Gmail
function send_report_to_gmail(sender_email, sender_pwd, receiver_email, report_text)
    if isempty(sender_email) || isempty(sender_pwd) || isempty(receiver_email)
        fprintf('Email 寄送失敗: 環境變數未正確讀取。\n');
        return;
    end

    setpref('Internet', 'E_mail', sender_email);
    setpref('Internet', 'SMTP_Server', 'smtp.gmail.com');
    setpref('Internet', 'SMTP_Username', sender_email);
    setpref('Internet', 'SMTP_Password', sender_pwd);
    
    props = java.lang.System.getProperties;
    props.setProperty('mail.smtp.auth', 'true');
    props.setProperty('mail.smtp.ssl.trust', 'smtp.gmail.com');
    props.setProperty('mail.smtp.port', '587');
    props.setProperty('mail.smtp.starttls.enable', 'true');
    
    subject = sprintf('【量化總經快訊晨報】%s', datestr(today, 'yyyy-mm-dd'));
    
    try
        sendmail(receiver_email, subject, report_text);
    catch ME
        fprintf('Email 寄送失敗: %s\n', ME.message);
    end
end
