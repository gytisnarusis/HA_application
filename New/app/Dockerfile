FROM python:3.7
EXPOSE 5000
COPY . /app/
COPY templates/index.html /usr/share/nginx/html
WORKDIR /app
RUN pip3 install -r requirements.txt
CMD python3 app.py