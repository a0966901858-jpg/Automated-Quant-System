% =========================================================================
% 自動化總經與量化交易日報系統 (Automated_Macro_Quant_System.m)
% 整合專案：爬蟲資料庫 + 均值回歸配對(S&P500 vs 台股) + Gemini API (含漲跌幅晨報) + GitHub Actions
% =========================================================================

function Automated_Macro_Quant_System()
    try
        clc; clear; close all;
        fprintf('[%s] 系統啟動，開始執行每日量化與總經資料更新...\n', datestr(now));
        
        %% 參數設定區 (讀取 GitHub Secrets 環境變數，確保資安)
           gemini_api_keys = {
            getenv('GEMINI_API_KEY_1'), ...
            getenv('GEMINI_API_KEY_2'), ...
            getenv('GEMINI_API_KEY_3'), ...
            getenv('GEMINI_API_KEY_4'), ...
            getenv('GEMINI_API_KEY_5'), ...
            getenv('GEMINI_API_KEY_6'), ...
            getenv('GEMINI_API_KEY_7'), ...
            getenv('GEMINI_API_KEY_8'), ...
            getenv('GEMINI_API_KEY_9'), ...
            getenv('GEMINI_API_KEY_10')
        }; 
        
        % 濾除空的 API Keys
        gemini_api_keys = gemini_api_keys(~cellfun(@isempty, gemini_api_keys));
        if isempty(gemini_api_keys)
            error('未偵測到任何 Gemini API Key，請檢查 GitHub Secrets 設定。');
        end
        
        sender_email = getenv('GMAIL_SENDER');      
        sender_pwd = getenv('GMAIL_PWD');           
        receiver_email = getenv('GMAIL_RECEIVER');  
        
        %% Phase 1: 總體經濟與大盤數據爬蟲 (新增計算漲跌幅)
        fprintf('正在爬取全球總經與市場數據...\n');
        
        tickers = {'^TWII', '^GSPC', '^IXIC', 'GC=F', 'BTC-USD', 'CL=F', '^TNX'};
        field_keys = {'TWII', 'SP500', 'NASDAQ', 'Gold', 'BTC', 'Oil', 'US10Y'}; 
        names = {'台灣加權指數', '標普500指數', '納斯達克指數', '黃金價格', '比特幣', '國際原油', '美10年期公債殖利率'};
        
        market_data = struct();
        start_dt = datetime('today', 'TimeZone', 'local') - calmonths(6); 
        
        for i = 1:length(tickers)
            [~, prices, last_price] = fetch_yahoo_data(tickers{i}, start_dt);
            
            % 計算當日漲跌幅 (%)
            if length(prices) >= 2
                % 對於公債殖利率，通常看絕對基點變化，但為了版面統一，這裡皆計算相對百分比變化
                change_pct = ((prices(end) - prices(end-1)) / prices(end-1)) * 100;
            else
                change_pct = 0;
            end
            
            % 將報價與漲跌幅存入資料庫
            market_data.(field_keys{i}) = struct('Prices', prices, 'Last', last_price, 'ChangePct', change_pct);
            fprintf(' - %s 更新完成 (最新報價: %.2f, 漲跌幅: %+.2f%%)\n', names{i}, last_price, change_pct);
        end
        
        % 國際大事爬蟲 
        fprintf('正在爬取國際財經頭條...\n');
        news_headlines = fetch_financial_news();
        
        %% Phase 2: 均值回歸與配對分析 (以標普500 vs 台灣加權指數為例)
        fprintf('進行大盤指數之斯皮爾曼相關性與 Z-Score 檢定...\n');
        
        p_sp500 = market_data.SP500.Prices;
        p_twii = market_data.TWII.Prices;
        
        min_len = min(length(p_sp500), length(p_twii));
        p_sp500 = p_sp500(end-min_len+1:end);
        p_twii = p_twii(end-min_len+1:end);
        
        ret_sp500 = diff(p_sp500) ./ p_sp500(1:end-1);
        ret_twii = diff(p_twii) ./ p_twii(1:end-1);
        
        logY = log(p_twii);
        logX = log(p_sp500);
        c = cov(logX, logY);
        current_beta = c(1,2) / c(1,1);
        
        spread = logY - current_beta * logX;
        z_score = (spread(end) - mean(spread)) / std(spread);
        
        %% Phase 3: 呼叫 Gemini API 產出投資日報 (極簡晨報版，加入漲跌幅)
        fprintf('正在呼叫 Gemini API 進行資訊整合...\n');
        
        % %+.2f%% 的加號代表：如果是正數會強制顯示 '+' 號，負數自動帶 '-' 號，非常適合財經報價
        prompt = sprintf([...
            '你是一位專業且俐落的財經晨報主播。請根據以下最新數據與新聞，產出一份「一分鐘完讀」的快訊版晨報，語氣明快、精準、直接給結論。\n\n', ...
            '【市場昨收報價與漲跌幅】\n', ...
            '台股: %.2f (%+.2f%%) | 標普500: %.2f (%+.2f%%) | 納斯達克: %.2f (%+.2f%%)\n', ...
            '黃金: %.2f (%+.2f%%) | 比特幣: %.2f (%+.2f%%) | 原油: %.2f (%+.2f%%) | 美10年期公債殖利率: %.2f (%+.2f%%)\n\n', ...
            '【配對訊號 (S&P 500 vs 台股加權指數)】\n', ...
            '價差 Z-Score: %.2f\n\n', ...
            '【國際財經大事】\n%s\n\n', ...
            '【任務要求（嚴格遵守）】\n', ...
            '1. 【市場速讀】：用一句話總結今日全球市場主旋律（例如：避險情緒升溫、資金擁擠等）與關鍵大事。\n', ...
            '2. 【資金前瞻】：根據「美債殖利率」與「大宗商品（金/油/幣）」的波動，一針見血指出對「美股」與「台股」板塊的潛在資金推力或壓力。\n', ...
            '3. 【量化定調】：結合 Z-Score 數值 (大於 2 代表台股相對美股溢價，小於 -2 代表相對折價)，給出今日極簡的部位操作提示。\n', ...
            '4. 【格式限制】：總字數嚴格控制在 250 字以內。全程採用條列式（Bullet points），拒絕冗長的背景解釋，只講結論與重點。'], ...
            market_data.TWII.Last, market_data.TWII.ChangePct, ...
            market_data.SP500.Last, market_data.SP500.ChangePct, ...
            market_data.NASDAQ.Last, market_data.NASDAQ.ChangePct, ...
            market_data.Gold.Last, market_data.Gold.ChangePct, ...
            market_data.BTC.Last, market_data.BTC.ChangePct, ...
            market_data.Oil.Last, market_data.Oil.ChangePct, ...
            market_data.US10Y.Last, market_data.US10Y.ChangePct, ...
            z_score, news_headlines);
            
        report_content = call_gemini_api_with_rotation(prompt, gemini_api_keys);
        fprintf('\n=== Gemini 報告生成成功 ===\n');
        
        %% Phase 4: 發送 Gmail
        fprintf('正在透過 Gmail 發送日報...\n');
        send_report_to_gmail(sender_email, sender_pwd, receiver_email, report_content);
        
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
    options = weboptions('UserAgent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36', 'Timeout', 20);
    
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

% 2. 爬取國際財經新聞 (RSS)
function headlines = fetch_financial_news()
    try
        rss_url = 'https://finance.yahoo.com/news/rssindex';
        options = weboptions('Timeout', 15);
        rss_data = webread(rss_url, options);
        
        headlines = '';
        items = rss_data.channel.item;
        num_items = min(3, length(items));
        for i = 1:num_items
            headlines = [headlines, '- ', items(i).title, char(10)];
        end
    catch
        headlines = '- 無法取得最新國際新聞。';
    end
end

% 3. 多金鑰輪替與防封鎖呼叫機制
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
            fprintf('API 忙碌或無回應，冷卻 %d 秒後進行第 %d 次重試...\n', cooldown, attempt); 
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
            if attempt >= maxRetries 
                report_text = sprintf('分析失敗。已達最大重試次數 (%d)。錯誤原因: %s', maxRetries, ME.message); 
            end
        end
    end
end

% 4. 寄送 Gmail
function send_report_to_gmail(sender_email, sender_pwd, receiver_email, report_text)
    if isempty(sender_email) || isempty(sender_pwd) || isempty(receiver_email)
        fprintf('Email 寄送失敗: 環境變數 (Secrets) 未正確讀取，請檢查 GitHub 設定。\n');
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
